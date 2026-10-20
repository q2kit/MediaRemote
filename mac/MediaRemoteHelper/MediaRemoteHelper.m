// Loaded into /usr/bin/perl by NowPlayingMonitor (see there for why). Since macOS 15.4
// MediaRemote only hands Now Playing info to Apple-signed processes, and perl is one that
// still allows loading third-party libraries.
//
// Prints one JSON object per line to stdout whenever the Now Playing state changes.
// Artwork (base64) is only included, together with "artworkChanged": true, when it changes.
// "clients" lists every app with a Now Playing session, not just the one being controlled.
//
// Reads commands from stdin, one per line:
//   "seek <seconds>"
//   "select <bundle id>"  make that app the one playback commands go to
//   "select"              go back to the app macOS picks itself
//
// About "select": MediaRemote sends every command to a single app, the one macOS elected as Now
// Playing, and asking for a specific app gets quietly redirected to it. What does work is the
// daemon's Now Playing override, but that is system wide: while it's on, the Mac's media keys and
// Control Center follow it too, and macOS stops electing apps on its own. It also stays in place
// when this process dies. So the override is only held while the app asks for it, it's dropped as
// soon as some other app starts playing (someone is using the Mac itself) or the picked app goes
// away, and it's cleared whenever the helper starts or exits.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>

typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetNowPlayingClients)(dispatch_queue_t, void (^)(NSArray *));
typedef id (*MRGetLocalOrigin)(void);
typedef void (*MRRegisterForNotifications)(dispatch_queue_t);
typedef void (*MRSetElapsedTime)(double);
typedef void (*MRSetOverrideEnabled)(Boolean);
typedef void (*MRSetOverriddenApplication)(NSString *);

@interface NSObject (MediaRemotePrivate)
- (instancetype)initWithOrigin:(id)origin client:(id)client player:(id)player;
- (instancetype)initWithPlayerPath:(id)playerPath;
- (void)requestNowPlayingInfoOnQueue:(dispatch_queue_t)queue completion:(void (^)(id))completion;
@end

static MRGetNowPlayingInfo getNowPlayingInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetNowPlayingClients getNowPlayingClients;
static MRGetLocalOrigin getLocalOrigin;
static MRSetElapsedTime setElapsedTime;
static MRSetOverrideEnabled setOverrideEnabled;
static MRSetOverriddenApplication setOverriddenApplication;
static dispatch_queue_t queue;
static NSString *lastLine;
static NSData *lastArtwork;

/// The app picked with "select", nil while macOS decides.
static NSString *selectedBundleID;
/// When each app was last seen playing, to tell a real start from the short gap between two tracks.
static NSMutableDictionary<NSString *, NSDate *> *lastPlaying;
static BOOL haveSeenClients;
static const NSTimeInterval kTrackGap = 3;

static id valueForKey(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *nowPlayingBundleID(void) {
    Class request = NSClassFromString(@"MRNowPlayingRequest");
    if (![request respondsToSelector:NSSelectorFromString(@"localNowPlayingPlayerPath")]) return nil;
    id bundleID = valueForKey(valueForKey(valueForKey(request, @"localNowPlayingPlayerPath"), @"client"), @"bundleIdentifier");
    return [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
}

static void copyValue(NSDictionary *info, NSString *key, NSMutableDictionary *out, NSString *name, Class type) {
    id value = info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:key]];
    if ([value isKindOfClass:type]) out[name] = value;
}

// MARK: - Override

static BOOL canSelect(void) {
    return setOverrideEnabled && setOverriddenApplication;
}

/// Only the process holding the override can turn it off, so take it over first. That also clears
/// one left behind by an earlier helper that was killed.
static void clearOverride(void) {
    if (!canSelect()) return;
    setOverrideEnabled(true);
    setOverriddenApplication(nil);
    setOverrideEnabled(false);
}

static void refresh(void);

static void selectSource(NSString *bundleID) {
    if (!canSelect()) return;
    if (bundleID) {
        setOverrideEnabled(true);
        setOverriddenApplication(bundleID);
    } else if (selectedBundleID) {
        clearOverride();
    }
    selectedBundleID = bundleID;
    refresh();
}

static void exitClearingOverride(int status) {
    clearOverride();
    exit(status);
}

/// Lets macOS pick again once the Mac itself is being used: another app started playing after a
/// real pause, or the picked app is gone.
static void followMacIfNeeded(NSArray<NSDictionary *> *clients) {
    NSDate *now = [NSDate date];
    BOOL release = selectedBundleID && ![[clients valueForKey:@"id"] containsObject:selectedBundleID];
    for (NSDictionary *client in clients) {
        if (![client[@"playing"] boolValue]) continue;
        NSString *bundleID = client[@"id"];
        NSDate *last = lastPlaying[bundleID];
        if (haveSeenClients && selectedBundleID && ![bundleID isEqualToString:selectedBundleID]
            && (!last || [now timeIntervalSinceDate:last] > kTrackGap)) {
            release = YES;
        }
        lastPlaying[bundleID] = now;
    }
    haveSeenClients = YES;
    if (release) {
        clearOverride();
        selectedBundleID = nil;
    }
}

// MARK: - Reading

/// Every app with a Now Playing session, read one by one. Calls back on `queue`.
static void readClients(void (^completion)(NSArray<NSDictionary *> *)) {
    if (!getNowPlayingClients || !getLocalOrigin) {
        completion(@[]);
        return;
    }
    getNowPlayingClients(queue, ^(NSArray *clients) {
        id origin = getLocalOrigin();
        Class pathClass = NSClassFromString(@"MRPlayerPath");
        Class requestClass = NSClassFromString(@"MRNowPlayingRequest");
        NSMutableArray<NSMutableDictionary *> *results = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        // Answers arrive on another queue: `queue` is busy right here.
        dispatch_queue_t answers = dispatch_queue_create("MediaRemoteHelper.clients", DISPATCH_QUEUE_SERIAL);

        for (id client in [clients isKindOfClass:NSArray.class] ? clients : @[]) {
            NSString *bundleID = valueForKey(client, @"bundleIdentifier");
            if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) continue;
            NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObject:bundleID forKey:@"id"];
            id name = valueForKey(client, @"displayName");
            entry[@"name"] = [name isKindOfClass:NSString.class] ? name : bundleID;
            id parent = valueForKey(client, @"parentApplicationBundleIdentifier");
            if ([parent isKindOfClass:NSString.class]) entry[@"parent"] = parent;
            entry[@"playing"] = @NO;
            [results addObject:entry];

            id request = [[requestClass alloc] initWithPlayerPath:[[pathClass alloc] initWithOrigin:origin client:client player:nil]];
            if (![request respondsToSelector:@selector(requestNowPlayingInfoOnQueue:completion:)]) continue;
            dispatch_group_enter(group);
            [request requestNowPlayingInfoOnQueue:answers completion:^(id info) {
                if ([info isKindOfClass:NSDictionary.class]) {
                    // The playback state query crashes for other apps; the rate says the same thing.
                    NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
                    entry[@"playing"] = [rate isKindOfClass:NSNumber.class] && rate.doubleValue > 0 ? @YES : @NO;
                    copyValue(info, @"Title", entry, @"title", NSString.class);
                }
                dispatch_group_leave(group);
            }];
        }

        // Don't wait forever on an app that never answers. A late answer still writes to its
        // entry, so the snapshot is taken on the queue the answers arrive on.
        __block BOOL done = NO;
        void (^finish)(void) = ^{
            if (done) return;
            done = YES;
            __block NSArray<NSDictionary *> *snapshot;
            dispatch_sync(answers, ^{ snapshot = [[NSArray alloc] initWithArray:results copyItems:YES]; });
            completion(snapshot);
        };
        dispatch_group_notify(group, queue, finish);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue, finish);
    });
}

static void emit(NSDictionary *info, BOOL playing, NSArray<NSDictionary *> *clients) {
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
    out[@"clients"] = clients;
    out[@"selectable"] = @(canSelect());
    if (selectedBundleID) out[@"selected"] = selectedBundleID;

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
    readClients(^(NSArray<NSDictionary *> *clients) {
        followMacIfNeeded(clients);
        // Read after a possible release, so the info matches the app commands now go to.
        getNowPlayingInfo(queue, ^(NSDictionary *info) {
            getIsPlaying(queue, ^(Boolean playing) {
                emit(info ?: @{}, playing, clients);
            });
        });
    });
}

// MARK: - Commands

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    if (parts.count == 2 && [parts[0] isEqualToString:@"seek"] && setElapsedTime) {
        setElapsedTime(MAX(parts[1].doubleValue, 0));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), queue, ^{ refresh(); });
    } else if (parts.count <= 2 && [parts[0] isEqualToString:@"select"]) {
        selectSource(parts.count == 2 && parts[1].length > 0 ? parts[1] : nil);
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
        if (count <= 0) exitClearingOverride(0); // the app closed our stdin: it is gone
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

/// The app stops the helper with SIGTERM; give back the override before going.
static void exitOnSignals(void) {
    static NSMutableArray *sources;
    sources = [NSMutableArray array];
    for (NSNumber *number in @[@(SIGTERM), @(SIGINT), @(SIGHUP)]) {
        int sig = number.intValue;
        signal(sig, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, queue);
        dispatch_source_set_event_handler(source, ^{ exitClearingOverride(0); });
        dispatch_resume(source);
        [sources addObject:source];
    }
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
    getNowPlayingClients = (MRGetNowPlayingClients)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
    getLocalOrigin = (MRGetLocalOrigin)dlsym(mr, "MRMediaRemoteGetLocalOrigin");
    setElapsedTime = (MRSetElapsedTime)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    setOverrideEnabled = (MRSetOverrideEnabled)dlsym(mr, "MRMediaRemoteSetNowPlayingApplicationOverrideEnabled");
    setOverriddenApplication = (MRSetOverriddenApplication)dlsym(mr, "MRMediaRemoteSetOverriddenNowPlayingApplication");
    MRRegisterForNotifications registerForNotifications =
        (MRRegisterForNotifications)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getNowPlayingInfo || !getIsPlaying) fail("MediaRemote symbols missing");

    queue = dispatch_queue_create("MediaRemoteHelper", DISPATCH_QUEUE_SERIAL);
    lastPlaying = [NSMutableDictionary dictionary];

    // A helper that was killed may have left its override behind.
    clearOverride();

    // Exit together with the app that launched us.
    dispatch_source_t parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)getppid(), DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(parentWatch, ^{ exitClearingOverride(0); });
    dispatch_resume(parentWatch);
    if (getppid() == 1) exit(0);
    exitOnSignals();

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
