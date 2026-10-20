# Media Remote

Ứng dụng iPhone điều khiển việc phát nhạc/video trên Mac qua mạng LAN: play/pause, bài trước/tiếp, tua, âm lượng, chọn đầu ra âm thanh, hiển thị bài đang phát (ảnh bìa, tên bài, nghệ sĩ, tiến trình).

Gồm hai ứng dụng:

- **Mac** — ứng dụng trên thanh menu, nhận kết nối từ iPhone và điều khiển hệ thống.
- **iPhone** — tìm Mac qua Bonjour, ghép đôi bằng mã PIN 6 số, rồi điều khiển.

## Ảnh chụp

Ảnh dùng dữ liệu demo; bản sáng/tối hiển thị theo giao diện GitHub của bạn.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ios-remote-dark.png">
    <img src="docs/screenshots/ios-remote-light.png" width="260" alt="Màn hình điều khiển trên iPhone">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ios-devices-dark.png">
    <img src="docs/screenshots/ios-devices-light.png" width="260" alt="Danh sách thiết bị trên iPhone">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/mac-menu-dark.png">
    <img src="docs/screenshots/mac-menu-light.png" width="306" alt="Menu trên thanh menu của Mac">
  </picture>
  &nbsp;
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/mac-about-dark.png">
    <img src="docs/screenshots/mac-about-light.png" width="319" alt="Cửa sổ thông tin trên Mac">
  </picture>
</p>

## Cấu trúc

```
shared/      Giao thức dùng chung (RemoteProtocol.swift) + đóng khung JSON theo dòng trên NWConnection
mac/         MediaRemoteMac.xcodeproj
  MediaRemoteMac/      Ứng dụng thanh menu (SwiftUI + AppKit)
  MediaRemoteHelper/   dylib Objective-C đọc thông tin Now Playing (xem bên dưới)
iphone/      MediaRemote.xcodeproj — ứng dụng SwiftUI
tools/       make-icon.swift — vẽ icon cho cả hai ứng dụng
docs/        Ảnh chụp màn hình cho README
```

## Yêu cầu

- Xcode 16 trở lên (project dùng file-system synchronized groups)
- macOS 14+, iOS 17+

## Tải bản Mac

Tải `MediaRemoteMac.zip` từ [bản phát hành mới nhất của ứng dụng Mac](https://github.com/q2kit/MediaRemote/releases) (tag `mac-v…`), giải nén rồi chuyển **MediaRemoteMac.app** vào Applications. Ứng dụng iPhone chưa có bản dựng sẵn, vẫn cài từ Xcode như phần Build bên dưới.

Bản phát hành chưa được Apple notarize, nên lần đầu mở macOS sẽ chặn. Mở *System Settings → Privacy & Security*, kéo xuống và bấm **Open Anyway**, hoặc chạy một lần trong Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/MediaRemoteMac.app
```

## Build

Mở `mac/MediaRemoteMac.xcodeproj` và `iphone/MediaRemote.xcodeproj` trong Xcode rồi Run như bình thường. Target `MediaRemoteHelper` được build và nhúng tự động vào ứng dụng Mac.

Build bằng dòng lệnh:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project mac/MediaRemoteMac.xcodeproj -scheme MediaRemoteMac build
xcodebuild -project iphone/MediaRemote.xcodeproj -scheme MediaRemote \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Khi chụp ảnh demo, có thể đặt tên máy và mã PIN qua tham số khởi động (không ghi vào cài đặt):

```sh
open -n MediaRemoteMac.app --args -serviceName "MacBook Pro" -pairingPIN 123456
```

### Ký ứng dụng

- Bundle ID mặc định là `com.q2k.MediaRemote` và `com.q2k.MediaRemoteMac`; đổi sang ID của bạn trước khi chạy trên máy thật.
- Chọn **Team** cho target iPhone để cài lên máy. Dùng Apple ID miễn phí (Personal Team) được, nhưng ứng dụng hết hạn sau 7 ngày và không có push notification.
- Nên chọn Team cho cả `MediaRemoteMac` và `MediaRemoteHelper`. Khi ký ad-hoc, chữ ký đổi sau mỗi lần build nên macOS coi là ứng dụng mới và quyền Trợ năng bị mất.

### Phát hành (chỉ ứng dụng Mac)

CI (`.github/workflows/build-macos.yml`) chỉ build và phát hành **ứng dụng Mac**; ứng dụng iPhone chưa nằm trong CI, khi nào làm sẽ có workflow và tag riêng.

- Mỗi pull request vào `main` có thay đổi trong `mac/`, `shared/` hoặc chính workflow đó đều được build để chắc chắn còn biên dịch được.
- Pull request như vậy phải nâng phiên bản ứng dụng Mac: *target MediaRemoteMac → General → Version* (`MARKETING_VERSION`). Bước kiểm tra sẽ báo lỗi nếu phiên bản đó đã phát hành.
- Khi merge, CI phát hành `mac-v<phiên bản>` kèm `MediaRemoteMac.zip`. Số build là số lần chạy CI.
- Bản phát hành được ký bằng chứng chỉ tự ký lưu trong secrets `SIGNING_CERTIFICATE_P12` (file .p12 mã hoá base64) và `SIGNING_CERTIFICATE_PASSWORD`, để các bản sau vẫn được macOS nhận là cùng một ứng dụng và giữ quyền Trợ năng, Mạng cục bộ. Chưa có secrets thì CI ký ad-hoc và báo cảnh báo.

## Quyền truy cập

- **Mạng cục bộ** — cả hai ứng dụng (Bonjour `_mediaremote._tcp`, khai báo trong `Info.plist`).
- **Trợ năng (Mac)** — chỉ cần cho đường dự phòng bằng phím media giả lập: khi MediaRemote không dùng được, hoặc khi đầu ra âm thanh không cho chỉnh âm lượng trực tiếp (HDMI/DisplayPort). Menu chỉ nhắc khi thật sự cần.

## Ghi chú kỹ thuật

- **Giao thức**: mỗi message là một dòng JSON (`RemoteMessage`). iPhone gửi `hello` kèm PIN; Mac trả `welcome` + `state`, hoặc `denied` rồi ngắt. Sau đó Mac đẩy `state` khi có thay đổi, ảnh bìa gửi riêng bằng `artwork`. Hai ứng dụng dùng chung file nên thay đổi giao thức phải giữ tương thích.
- **Now Playing**: từ macOS 15.4, MediaRemote chỉ trả thông tin cho tiến trình do Apple ký. Ứng dụng Mac chạy `/usr/bin/perl` và nạp `libMediaRemoteHelper.dylib` vào đó; helper ghi JSON ra stdout và nhận lệnh (`seek`, `select`) qua stdin. Đây là API riêng nên có thể hỏng ở bản macOS sau — khi đó điều khiển vẫn hoạt động, chỉ mất thông tin bài đang phát.
- **Điều khiển phát**: gửi qua `MRMediaRemoteSendCommand` (không cần quyền); phím media giả lập chỉ là dự phòng. Âm lượng và đầu ra âm thanh dùng CoreAudio.
- **Chọn nguồn phát**: khi nhiều app cùng có nhạc/video, iPhone hiện mỗi app một chấm phía trên ảnh bìa; vuốt ngang màn điều khiển (hoặc chạm vào chấm) để chuyển app. Chấm dài hơn, kèm tên bên dưới, là app đang nhận lệnh, kể cả khi chưa chọn gì và macOS tự chọn như bình thường. MediaRemote luôn gửi lệnh tới app mà macOS đang coi là Now Playing, hỏi đích danh app khác cũng bị chuyển về app đó. Vì vậy khi bạn chọn một app, helper ghi đè lựa chọn Now Playing của hệ thống. Việc ghi đè này có hiệu lực cho cả Mac: phím media và Control Center cũng điều khiển app đó, và macOS tạm ngừng tự chọn. Nên nó chỉ được giữ khi cần: bỏ ngay khi trên Mac có app khác bắt đầu phát (tức là bạn đang dùng Mac), khi app đã chọn tắt, khi iPhone cuối cùng ngắt kết nối, hoặc khi ứng dụng Mac thoát. Helper bị kill đột ngột thì lần chạy kế tiếp sẽ dọn lại.
- **Tích hợp SoundControl** (*Settings › Extensions › SoundControl*, bật sẵn): nếu [SoundControl](https://github.com/q2kit/SoundControl) đang chạy trên Mac, thanh âm lượng trên iPhone chỉnh âm lượng riêng của app đang điều khiển thay vì âm lượng chung của Mac, và nút đầu ra chọn loa cho riêng app đó (kèm âm lượng của chính loa ấy). Hai app nói chuyện qua socket `~/Library/Application Support/SoundControl/control.sock`; không có SoundControl, hoặc tắt mục này, thì mọi thứ như cũ. Mục này cũng cho biết đã kết nối được với SoundControl hay chưa. Mỗi trình duyệt chỉ báo một nguồn phát cho macOS (tab phát gần nhất), nên các tab không chọn riêng được.
- **Bảo mật**: một mã PIN dùng chung cho mọi thiết bị, lưu trong `UserDefaults`; kết nối chưa mã hoá. Đủ cho dùng trong mạng nhà, chưa phù hợp mạng công cộng.
- **Ngôn ngữ**: tiếng Anh (gốc) và tiếng Việt qua String Catalog (`Localizable.xcstrings`, `InfoPlist.xcstrings`).

## Icon

```sh
swift tools/make-icon.swift iphone/MediaRemote/Assets.xcassets/AppIcon.appiconset/AppIcon.png ios
swift tools/make-icon.swift iphone/MediaRemote/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png ios-dark
swift tools/make-icon.swift mac/MediaRemoteMac/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png mac
```

Các cỡ icon Mac nhỏ hơn được tạo từ bản 1024px bằng `sips -z`.
