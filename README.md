# Barky iOS SDK

앱 안에서 고객이 바로 대화를 시작할 수 있는 네이티브 채팅 SDK입니다.
SwiftUI `ChatView`와 UIKit `ChatViewController`를 제공하며 외부 패키지 의존성이 없습니다.

- iOS 16 이상 · Swift 5.9 이상 · Swift Package Manager
- 텍스트 메시지 송수신, 대화 복원, 전송 실패 재시도
- 고객 세션 갱신, 화면이 활성화된 동안 답변 자동 조회
- 한국어/영어, Dynamic Type, VoiceOver, 다크 모드
- 첨부 파일, 푸시 알림, 읽음 표시, 상담원 온라인 상태는 제공하지 않습니다.

## 설치

Xcode의 **File → Add Package Dependencies…**에서 아래 저장소 URL을 입력하고
`0.1.0` 이상을 선택한 뒤 앱 타깃에 **Barky** product를 추가하세요.

```text
https://github.com/barky-io/barky-ios-sdk.git
```

다른 Swift 패키지에서는 다음과 같이 추가합니다.

```swift
dependencies: [
    .package(url: "https://github.com/barky-io/barky-ios-sdk.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Barky", package: "barky-ios-sdk")
    ])
]
```

로컬 개발 시에는 **Add Local…**로 이 저장소 폴더를 선택할 수도 있습니다.
모듈 이름은 `Barky`이며, 저장소 루트의 `Package.swift`가 설치 진입점입니다.

## SwiftUI에서 사용

로그인한 사용자의 백엔드 세션을 얻을 수 있을 때, 메인 액터에서 한 번 설정하세요.
`apiURL`은 `/api/v1`을 포함한 Barky API 주소입니다.

```swift
import Barky
import SwiftUI

@MainActor
func configureSupport() throws {
    try BarkySDK.configure(BarkyConfiguration(
        apiURL: URL(string: "https://YOUR_BARKY_HOST/api/v1")!,
        storageNamespace: "YOUR_CHANNEL_ID"
    ) {
        // 앱의 기존 인증된 네트워크 계층으로 구현하는 함수입니다.
        // 백엔드가 반환한 JSON을 JSONDecoder().decode(BarkySession.self, from: data)로 변환하세요.
        try await AppBackend.fetchBarkySession()
    })
}

struct SupportButton: View {
    @State private var showsChat = false

    var body: some View {
        Button("문의하기") { showsChat = true }
            .sheet(isPresented: $showsChat) {
                ChatView()
            }
    }
}
```

`AppBackend.fetchBarkySession()`은 호스트 앱이 제공하는 인증 연동 지점입니다.
콜백은 초기 연결, 세션 만료 30초 전, HTTP 401 이후에 호출되므로 항상 **현재 사용자의 새 고객 세션**을 반환해야 합니다.
SDK는 앱 사용자 인증 방식이나 앱 백엔드 주소를 가정하지 않습니다.

백엔드는 인증된 사용자의 ID를 직접 결정한 뒤, 서버에 보관한 채널 키로
`POST /api/v1/customer-sessions`를 호출합니다. 앱에 반환하는 형태:

```json
{
  "token": "bk_session_…",
  "customerId": "customer-uuid",
  "expiresAt": "2026-09-06T10:00:00.000Z"
}
```

**채널 서버 키를 앱에 넣으면 안 됩니다.** SDK는 `bk_session_` 고객 토큰만 받습니다.
익명 사용자를 지원하려면 앱 백엔드가 검증 가능한 익명 사용자 세션을 먼저 제공해야 합니다.
공개 웹사이트 ID만으로 토큰을 발급받는 API는 현재 Barky에 없습니다.

## UIKit / 화면 꾸미기

```swift
// UIKit, 메인 액터에서 호출
present(ChatViewController(), animated: true)

// SwiftUI
ChatView(appearance: ChatAppearance(
    title: "고객 지원",
    welcomeTitle: "안녕하세요!",
    welcomeMessage: "궁금한 점을 남겨 주세요.",
    accentColor: .indigo
))
```

화면 자체에 헤더와 닫기 버튼이 있습니다. 호스트 내비게이션을 사용하면
`ChatAppearance(showsCloseButton: false)`로 닫기 버튼을 숨길 수 있습니다.
사용자 지정 색상은 `outgoingTextColor`와 함께 대비를 확인하세요.

SDK는 한국어/영어 리소스를 포함합니다. 호스트 앱이 해당 언어를 선언하지 않았다면
앱 Info.plist에 `CFBundleAllowMixedLocalizations = YES`를 추가해야 SDK의 언어가
기기 언어에 맞춰 선택됩니다. 예제 앱에는 이 설정이 포함되어 있습니다.

독립된 인스턴스를 사용하려면 `try BarkyClient(configuration: configuration)`을 만들고
`ChatView(client: client)` 또는 `ChatViewController(client: client)`에 전달하세요.
동일한 고객/채널에는 하나의 클라이언트를 공유하세요.

## 대화 수명과 로그아웃

빈 화면을 열면 메시지 작성이 가능하고, 첫 전송 시 대화가 만들어집니다.
이후 같은 대화에 메시지가 추가됩니다. 화면을 닫았다 열거나 앱을 다시 실행해도 고객별 Keychain 기록으로 대화를 복원합니다.
화면을 닫거나 앱이 백그라운드로 이동하면 자동 조회가 중지됩니다. 이미 시작한 전송은 완료할 수 있습니다.

사용자를 바꾸거나 로그아웃할 때, **앱의 사용자 인증 정보를 바꾸기 전에** 호출하세요.

```swift
BarkySDK.logout()
// 새 사용자 로그인 후 새 sessionProvider로 configureSupport()를 다시 호출합니다.
```

로그아웃은 화면/메모리/자격 증명을 비우고 진행 중인 작업을 무효화합니다.
같은 사용자의 향후 복원을 위해 Keychain 기록은 유지합니다.
현재 사용자의 로컬 기록도 지우려면 로그아웃 대신 `try BarkySDK.shared.forgetLocalConversation()`을 호출하세요.
이는 서버 메시지를 삭제하지 않습니다. 전송 결과가 불확실한 메시지는 서버에 이미 도착했을 수 있습니다.

현재 API에는 고객용 대화 목록 조회가 없습니다. 여러 대화 선택 화면은 제공하지 않으며,
기기 간 복원에는 백엔드가 고객 세션 응답에 소유권을 확인한 `conversationId`를 추가해야 합니다.
SDK의 `conversationID`로 생성된 대화 ID를 확인할 수 있습니다.
기존 로컬 대화나 재시도할 요청이 있으면 해당 기록이 우선합니다.

## 예제와 검증

`Examples/BarkyDemo/BarkyDemo.xcodeproj`를 열어 **BarkyDemo**를 실행하세요.
예제는 로컬 SPM 패키지를 참조하며, 서버 없이 동작하는 데모 전용 전송 계층을 사용합니다.
"Fail the next send"로 실패/재전송 UI를 확인할 수 있습니다. 합성 답변은 예제 앱에만 있습니다.

```sh
swift test
```

핵심 테스트는 인증, 페이지 처리, 네트워크 실패, 요청 중복 방지, 저장소 오류,
계정 변경과 복원을 검사합니다. 실제 서버 통합 테스트는 환경 변수가 없으면 건너뜁니다.
추가 검증 범위와 iOS UI 테스트 실행 방법은 [검증 문서](Documentation/Testing.md)에 있습니다.

## 구현 출처와 데이터 처리

Crisp의 [공개 README](https://github.com/crisp-im/crisp-sdk-ios)에서 SPM 설치와
설정 후 채팅 화면을 여는 사용 흐름만 참고했습니다. Crisp 구현 소스, 바이너리, 이미지,
아이콘, 문구를 가져오거나 의존성으로 사용하지 않았습니다. UI는 SwiftUI와 시스템 SF Symbols로 별도 구현했습니다.

데이터 저장/전송 범위와 Privacy Manifest는 [개인정보 문서](Documentation/Privacy.md)를 참고하세요.
배포 라이선스는 [MIT](LICENSE)이며, 참고한 자료와 구현 출처는 [출처 문서](Documentation/Provenance.md)에 정리했습니다.
