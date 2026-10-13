// Loaded into /usr/bin/perl by NowPlayingMonitor (see there for why). Since macOS 15.4
// MediaRemote only hands Now Playing info to Apple-signed processes, and perl is one that
// still allows loading third-party libraries.
//
// Prints one JSON object per line to stdout whenever the Now Playing state changes.
// Artwork (base64) is only included, together with "artworkChanged": true, when it changes.
// Reads commands from stdin, one per line: "seek <seconds>".

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRRegisterForNotifications)(dispatch_queue_t);
typedef void (*MRSetElapsedTime)(double);

static MRGetNowPlayingInfo getNowPlayingInfo;
static MRGetIsPlaying getIsPlaying;
static MRSetElapsedTime setElapsedTime;
static dispatch_queue_t queue;
static NSString *lastLine;
static NSData *lastArtwork;

static NSString *nowPlayingBundleID(void) {
    Class request = NSClassFromString(@"MRNowPlayingRequest");
    if (![request respondsToSelector:NSSelectorFromString(@"localNowPlayingPlayerPath")]) return nil;
    @try {
        id path = [request valueForKey:@"localNowPlayingPlayerPath"];
        id bundleID = [[path valueForKey:@"client"] valueForKey:@"bundleIdentifier"];
        return [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
    } @catch (NSException *e) {
        return nil;
    }
}

static void copyValue(NSDictionary *info, NSString *key, NSMutableDictionary *out, NSString *name, Class type) {
    id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
    if ([value isKindOfClass:type]) out[name] = value;
}

static void emit(NSDictionary *info, BOOL playing) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"available"] = @YES;
    out[@"playing"] = @(playing);
    copyValue(info, @"Title", out, @"title", NSString.class);
    copyValue(info, @"Artist", out, @"artist", NSString.class);
    copyValue(info, @"Album", out, @"album", NSString.class);
    copyValue(info, @"Duration", out, @"duration", NSNumber.class);
    copyValue(info, @"ElapsedTime", out, @"elapsed", NSNumber.class);
    copyValue(info, @"PlaybackRate", out, @"rate", NSNumber.class);
    NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:NSDate.class]) out[@"timestamp"] = @(timestamp.timeIntervalSince1970);
    NSString *bundleID = nowPlayingBundleID();
    if (bundleID) out[@"bundleID"] = bundleID;

    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![artwork isKindOfClass:NSData.class] || artwork.length == 0) artwork = nil;
    BOOL artworkChanged = !(artwork == lastArtwork || [artwork isEqualToData:lastArtwork]);

    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (!artworkChanged && [line isEqualToString:lastLine]) return;
    lastLine = line;

    if (artworkChanged) {
        lastArtwork = artwork;
        out[@"artworkChanged"] = @YES;
        if (artwork) out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    }
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    getNowPlayingInfo(queue, ^(NSDictionary *info) {
        getIsPlaying(queue, ^(Boolean playing) {
            emit(info ?: @{}, playing);
        });
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    if (parts.count == 2 && [parts[0] isEqualToString:@"seek"] && setElapsedTime) {
        setElapsedTime(MAX(parts[1].doubleValue, 0));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), queue, ^{ refresh(); });
    }
}

static void listenForCommands(void) {
    // Static so ARC keeps them alive after this function returns.
    static NSMutableData *pending;
    static dispatch_source_t input;
    pending = [NSMutableData data];
    input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(input, ^{
        char chunk[1024];
        ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
        if (count <= 0) exit(0); // the app closed our stdin: it is gone
        [pending appendBytes:chunk length:(NSUInteger)count];
        NSRange newline;
        while ((newline = [pending rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, pending.length)]).location != NSNotFound) {
            NSData *lineData = [pending subdataWithRange:NSMakeRange(0, newline.location)];
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (line) handleCommand([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
        }
    });
    dispatch_resume(input);
}

static void fail(const char *message) {
    printf("{\"available\":false,\"error\":\"%s\"}\n", message);
    fflush(stdout);
    exit(1);
}

// Installed as a perl XSUB and called once; never returns.
__attribute__((visibility("default")))
void mrhelper_run(void *unusedInterpreter, void *unusedCV) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!mr) fail("MediaRemote not found");
    getNowPlayingInfo = (MRGetNowPlayingInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetIsPlaying)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    setElapsedTime = (MRSetElapsedTime)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegisterForNotifications registerForNotifications =
        (MRRegisterForNotifications)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getNowPlayingInfo || !getIsPlaying) fail("MediaRemote symbols missing");

    queue = dispatch_queue_create("MediaRemoteHelper", DISPATCH_QUEUE_SERIAL);

    // Exit together with the app that launched us.
    dispatch_source_t parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)getppid(), DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(parentWatch, ^{ exit(0); });
    dispatch_resume(parentWatch);
    if (getppid() == 1) exit(0);

    if (registerForNotifications) {
        registerForNotifications(queue);
        for (NSString *name in @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                dispatch_async(queue, ^{ refresh(); });
            }];
        }
    }

    listenForCommands();

    // Notifications aren't delivered reliably for every player, so poll as a fallback.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ refresh(); });
    dispatch_resume(timer);

    dispatch_main();
}
