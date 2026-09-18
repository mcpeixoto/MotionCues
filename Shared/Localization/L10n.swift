//
//  L10n.swift
//
//  Every user-facing string for Mac and iPhone. Looked up by the in-app
//  language preference, not by the system locale.
//

import Foundation

public enum L10n {
    public enum Key: String, CaseIterable {
        // Shared / common
        case yes, no, notYet, notReported
        case start, stop, quit, done, cancel, settingsEllipsis
        case intensity, sensor, language
        case low, medium, high
        case automatic, macAirPods, iPhone, simulator

        // Window / brand
        case welcomeWindowTitle, settingsWindowTitle
        case vehicleMotionCues, appName

        // Menu bar
        case statusInactive
        case statusActiveConnected  // %@ source, optional rate already appended by caller
        case statusActiveWaiting    // %@ source
        case statusRateSuffix       // · %.0f Hz
        case welcomeAndSetup
        case menuStart, menuStop

        // Appearance
        case tabAppearance, tabMotion, tabCalibration, tabSensors
        case dotSize, opacity, howFarInFromEdge
        case peripheryFooter
        case contrast
        case followSystem, darkDotsForLight, lightDotsForDark
        case includeVerticalCues, fadeDotsWhenStill, hideFromScreenCapture
        case contrastFooter
        case resetToDefaults

        // Motion
        case intensityFooter  // %d flowGain
        case filtering, smoothing, sensitivity, responsiveness
        case filteringEssay
        case liveReading
        case longitudinal, lateral, vertical
        case hintBrakeAccel, hintRightLeft, hintDownUp

        // Launch
        case openAtLogin
        case loginItemBlocked
        case loginItemFailed  // %@ error

        // Sensors
        case source
        case startCuesOnLaunch, onlyShowWhileMoving
        case linkStatus
        case activeSource, connected, sampleRate, transportJitter
        case droppedPackets, inAVehicle
        case motionPermission, headphoneMotionAvailable
        case macSensors, macSensorsFooter
        case privacy, privacyFooter

        // Auth
        case authGranted, authDenied, authRestricted, authNotRequested, authUnknown

        // Calibration
        case howItWorks, howItWorksBody, howItWorksDetail
        case status, calibrated, forwardAxis, confidence
        case accelBrakeSeen, corneringSeen
        case keepDrivingHint
        case calibrate, clearCalibration
        case startFirstForCalibration
        case fineTuning, keepRefining
        case manualAdjustment, fineTuningFooter

        // Welcome
        case welcomeBlurb
        case welcomeStep1Title, welcomeStep1Body
        case welcomeStep2Title, welcomeStep2Body
        case welcomeStep3Title, welcomeStep3Body
        case welcomeStep4Title, welcomeStep4Body
        case welcomeStep5Title, welcomeStep5Body
        case iPhoneConnected, waitingForPhone
        case motionPermissionLabel  // %@
        case tryWithoutCar

        // Receiver / headphones / simulator status
        case advertising  // %@ bonjour type
        case cannotListen  // %@
        case stopped
        case waitingForIPhoneOnPort  // %d
        case waitingForIPhone
        case listenerFailed  // %@
        case waitingWithError  // %@
        case connectedTo  // %@
        case connectedPlain
        case iPhoneDisconnected
        case noDataFromIPhone
        case motionAccessDeniedHeadphones
        case noMotionHeadphones
        case waitingForHeadphones
        case airPodsDegraded
        case headphonesDisconnected
        case syntheticDrive

        // iOS companion
        case startStreaming, stopStreaming
        case macsFound
        case keepScreenAwake, useGPSSpeed, detectVehicle
        case rightNow, speed
        case options
        case detectVehicleFooter
        case packetsSent, droppedBackpressure
        case link
        case linkFooter
        case ifWillNotConnect
        case tipLocalNetwork, tipMacRunning, tipWiFiOn
        case senderStopped, lookingForMac
        case connectingTo  // %@
        case streamingTo  // %@
        case problem  // %@
        case macStoppedResponding
        case driveUnknown, driveInVehicle, driveNotInVehicle
        case driveUnavailable, driveMotionDenied
        case deviceMotionUnavailable
        case locationDeniedRoll
    }

    public static func t(_ key: Key, _ language: AppLanguage = .current, _ args: CVarArg...) -> String {
        let template = table[key]?[language] ?? table[key]?[.english] ?? key.rawValue
        guard !args.isEmpty else { return template }
        return String(format: template, locale: language.locale, arguments: args)
    }

    // swiftlint:disable:next line_length
    private static let table: [Key: [AppLanguage: String]] = [
        .yes: [.english: "Yes", .chineseSimplified: "是"],
        .no: [.english: "No", .chineseSimplified: "否"],
        .notYet: [.english: "Not yet", .chineseSimplified: "尚未"],
        .notReported: [.english: "Not reported", .chineseSimplified: "未报告"],
        .start: [.english: "Start", .chineseSimplified: "开始"],
        .stop: [.english: "Stop", .chineseSimplified: "停止"],
        .quit: [.english: "Quit", .chineseSimplified: "退出"],
        .done: [.english: "Done", .chineseSimplified: "完成"],
        .cancel: [.english: "Cancel", .chineseSimplified: "取消"],
        .settingsEllipsis: [.english: "Settings…", .chineseSimplified: "设置…"],
        .intensity: [.english: "Intensity", .chineseSimplified: "强度"],
        .sensor: [.english: "Sensor", .chineseSimplified: "传感器"],
        .language: [.english: "Language", .chineseSimplified: "语言"],
        .low: [.english: "Low", .chineseSimplified: "低"],
        .medium: [.english: "Medium", .chineseSimplified: "中"],
        .high: [.english: "High", .chineseSimplified: "高"],
        .automatic: [.english: "Automatic", .chineseSimplified: "自动"],
        .macAirPods: [.english: "Mac (AirPods)", .chineseSimplified: "Mac（AirPods）"],
        .iPhone: [.english: "iPhone", .chineseSimplified: "iPhone"],
        .simulator: [.english: "Simulator", .chineseSimplified: "模拟器"],

        .welcomeWindowTitle: [
            .english: "Welcome to MotionCues",
            .chineseSimplified: "欢迎使用 MotionCues"
        ],
        .settingsWindowTitle: [
            .english: "MotionCues Settings",
            .chineseSimplified: "MotionCues 设置"
        ],
        .vehicleMotionCues: [
            .english: "Vehicle Motion Cues",
            .chineseSimplified: "车辆运动提示"
        ],
        .appName: [.english: "MotionCues", .chineseSimplified: "MotionCues"],

        .statusInactive: [
            .english: "Status: Inactive",
            .chineseSimplified: "状态：未运行"
        ],
        .statusActiveConnected: [
            .english: "Status: Active — %@",
            .chineseSimplified: "状态：运行中 — %@"
        ],
        .statusActiveWaiting: [
            .english: "Status: Active — waiting for %@",
            .chineseSimplified: "状态：运行中 — 正在等待 %@"
        ],
        .statusRateSuffix: [
            .english: " · %.0f Hz",
            .chineseSimplified: " · %.0f Hz"
        ],
        .welcomeAndSetup: [
            .english: "Welcome & Setup…",
            .chineseSimplified: "欢迎与设置…"
        ],
        .menuStart: [.english: "Start", .chineseSimplified: "开始"],
        .menuStop: [.english: "Stop", .chineseSimplified: "停止"],

        .tabAppearance: [.english: "Appearance", .chineseSimplified: "外观"],
        .tabMotion: [.english: "Motion", .chineseSimplified: "运动"],
        .tabCalibration: [.english: "Calibration", .chineseSimplified: "校准"],
        .tabSensors: [.english: "Sensors", .chineseSimplified: "传感器"],
        .dotSize: [.english: "Dot size", .chineseSimplified: "点大小"],
        .opacity: [.english: "Opacity", .chineseSimplified: "不透明度"],
        .howFarInFromEdge: [
            .english: "How far in from the edge",
            .chineseSimplified: "从边缘向内延伸"
        ],
        .peripheryFooter: [
            .english: "The cue lives in your peripheral vision. The middle of the screen is left clear, because that is where you are reading.",
            .chineseSimplified: "提示点出现在余光区域。屏幕中央留空，那是你阅读的位置。"
        ],
        .contrast: [.english: "Contrast", .chineseSimplified: "对比"],
        .followSystem: [.english: "Follow system", .chineseSimplified: "跟随系统"],
        .darkDotsForLight: [
            .english: "Dark dots (for light backgrounds)",
            .chineseSimplified: "深色点（适合浅色背景）"
        ],
        .lightDotsForDark: [
            .english: "Light dots (for dark backgrounds)",
            .chineseSimplified: "浅色点（适合深色背景）"
        ],
        .includeVerticalCues: [
            .english: "Include vertical (bump) cues",
            .chineseSimplified: "包含垂直（颠簸）提示"
        ],
        .fadeDotsWhenStill: [
            .english: "Fade dots down when the car is still",
            .chineseSimplified: "车辆静止时淡化提示点"
        ],
        .hideFromScreenCapture: [
            .english: "Hide overlay from screenshots and screen sharing",
            .chineseSimplified: "截屏与屏幕共享时隐藏叠加层"
        ],
        .contrastFooter: [
            .english: "The overlay cannot read what is behind it without Screen Recording permission. Rather than guess, every particle is drawn twice — once light, once dark, slightly offset — so whichever one contrasts with your content is the one you see.",
            .chineseSimplified: "没有屏幕录制权限时，叠加层无法读取背后内容。因此每个粒子会画两次——一次浅、一次深，并略微错开——哪一个与内容对比更强，你就会看见哪一个。"
        ],
        .resetToDefaults: [
            .english: "Reset to defaults",
            .chineseSimplified: "恢复默认"
        ],

        .intensityFooter: [
            .english: "How hard the car's motion drives the field: %d pt/s² per g. Start at Low.",
            .chineseSimplified: "车辆运动驱动粒子场的强度：每 g %d pt/s²。建议从「低」开始。"
        ],
        .filtering: [.english: "Filtering", .chineseSimplified: "滤波"],
        .smoothing: [.english: "Smoothing", .chineseSimplified: "平滑"],
        .sensitivity: [.english: "Sensitivity", .chineseSimplified: "灵敏度"],
        .responsiveness: [.english: "Responsiveness", .chineseSimplified: "响应速度"],
        .filteringEssay: [
            .english: "Smoothing sets how still the dots are at rest (the One Euro filter's cutoff floor). Sensitivity sets how far that cutoff opens under a fast manoeuvre, i.e. how little lag you get during hard braking. Responsiveness is the render-side spring: higher is snappier, lower is more fluid.",
            .chineseSimplified: "平滑决定静止时点有多稳（One Euro 滤波器的截止下限）。灵敏度决定急加减速时截止频率开多大，也就是急刹车时延迟有多小。响应速度是渲染侧的弹簧：越高越干脆，越低越顺滑。"
        ],
        .liveReading: [.english: "Live reading", .chineseSimplified: "实时读数"],
        .longitudinal: [.english: "Longitudinal", .chineseSimplified: "纵向"],
        .lateral: [.english: "Lateral", .chineseSimplified: "横向"],
        .vertical: [.english: "Vertical", .chineseSimplified: "垂直"],
        .hintBrakeAccel: [
            .english: "brake ← → accelerate",
            .chineseSimplified: "刹车 ← → 加速"
        ],
        .hintRightLeft: [
            .english: "right ← → left",
            .chineseSimplified: "右 ← → 左"
        ],
        .hintDownUp: [
            .english: "down ← → up",
            .chineseSimplified: "下 ← → 上"
        ],

        .openAtLogin: [
            .english: "Open MotionCues at login",
            .chineseSimplified: "登录时打开 MotionCues"
        ],
        .loginItemBlocked: [
            .english: "Turned off in System Settings › General › Login Items.",
            .chineseSimplified: "已在「系统设置 › 通用 › 登录项」中关闭。"
        ],
        .loginItemFailed: [
            .english: "Could not change this. macOS only accepts login items from a stable, signed location — move MotionCues to /Applications and try again. (%@)",
            .chineseSimplified: "无法更改。macOS 只接受来自稳定、已签名位置的登录项——请把 MotionCues 移到 /Applications 后再试。（%@）"
        ],

        .source: [.english: "Source", .chineseSimplified: "来源"],
        .startCuesOnLaunch: [
            .english: "Start cues automatically when the app launches",
            .chineseSimplified: "启动应用时自动开启提示"
        ],
        .onlyShowWhileMoving: [
            .english: "Only show cues while the car is moving",
            .chineseSimplified: "仅在车辆行驶时显示提示"
        ],
        .linkStatus: [.english: "Link status", .chineseSimplified: "连接状态"],
        .activeSource: [.english: "Active source", .chineseSimplified: "当前来源"],
        .connected: [.english: "Connected", .chineseSimplified: "已连接"],
        .sampleRate: [.english: "Sample rate", .chineseSimplified: "采样率"],
        .transportJitter: [.english: "Transport jitter", .chineseSimplified: "传输抖动"],
        .droppedPackets: [.english: "Dropped packets", .chineseSimplified: "丢包"],
        .inAVehicle: [.english: "In a vehicle", .chineseSimplified: "是否在车内"],
        .motionPermission: [.english: "Motion permission", .chineseSimplified: "运动权限"],
        .headphoneMotionAvailable: [
            .english: "Headphone motion available",
            .chineseSimplified: "耳机运动可用"
        ],
        .macSensors: [.english: "Mac sensors", .chineseSimplified: "Mac 传感器"],
        .macSensorsFooter: [
            .english: "This Mac has no built-in accelerometer or gyroscope — Core Motion's CMMotionManager is marked API_UNAVAILABLE(macos), and Apple Silicon Macs ship no inertial hardware. The only inertial source macOS exposes is head motion from AirPods (CMHeadphoneMotionManager, macOS 14+). It works, but head movement contaminates it, so the iPhone companion is the accurate path.",
            .chineseSimplified: "这台 Mac 没有内置加速度计或陀螺仪——Core Motion 的 CMMotionManager 在 macOS 上不可用，Apple Silicon Mac 也没有惯性硬件。macOS 唯一能用的惯性来源是 AirPods 头部运动（CMHeadphoneMotionManager，macOS 14+）。能用，但头部动作会干扰，准确路径仍是 iPhone 配套应用。"
        ],
        .privacy: [.english: "Privacy", .chineseSimplified: "隐私"],
        .privacyFooter: [
            .english: "All sensor data stays on this Mac and on your phone. There is no account, no cloud, no analytics and no Internet access of any kind — the link is a direct UDP stream over your local network or over peer-to-peer Wi-Fi.",
            .chineseSimplified: "所有传感器数据只留在本机 Mac 和手机上。没有账号、没有云、没有分析、也没有任何互联网访问——链路是局域网或点对点 Wi-Fi 上的直连 UDP 流。"
        ],

        .authGranted: [.english: "Granted", .chineseSimplified: "已授权"],
        .authDenied: [.english: "Denied", .chineseSimplified: "已拒绝"],
        .authRestricted: [.english: "Restricted", .chineseSimplified: "受限制"],
        .authNotRequested: [.english: "Not requested yet", .chineseSimplified: "尚未请求"],
        .authUnknown: [.english: "Unknown", .chineseSimplified: "未知"],

        .howItWorks: [.english: "How it works", .chineseSimplified: "原理"],
        .howItWorksBody: [
            .english: "MotionCues has to know which way the car points relative to the sensor. It works that out from the driving itself — you never have to align anything by hand.",
            .chineseSimplified: "MotionCues 需要知道车辆相对传感器朝向哪边。它从行驶过程中自行推算——你不必手动对齐。"
        ],
        .howItWorksDetail: [
            .english: "Place the Mac where you normally use it, put the phone wherever it will stay (pocket, cradle, cup holder — orientation does not matter, only that it does not slide around), press Calibrate, then just travel normally for about twenty seconds. Include at least one bend.",
            .chineseSimplified: "把 Mac 放在平常使用的位置，手机放在能固定住的地方（口袋、支架、杯架——朝向无关紧要，只要别滑动），按下「校准」，然后正常行驶大约二十秒，至少包含一次转弯。"
        ],
        .status: [.english: "Status", .chineseSimplified: "状态"],
        .calibrated: [.english: "Calibrated", .chineseSimplified: "已校准"],
        .forwardAxis: [.english: "Forward axis", .chineseSimplified: "前进轴"],
        .confidence: [.english: "Confidence", .chineseSimplified: "置信度"],
        .accelBrakeSeen: [
            .english: "Accel / brake seen",
            .chineseSimplified: "已检测到加速/刹车"
        ],
        .corneringSeen: [
            .english: "Cornering seen",
            .chineseSimplified: "已检测到转弯"
        ],
        .keepDrivingHint: [
            .english: "Keep driving. Braking and accelerating fix the axis; a bend resolves which way is forwards.",
            .chineseSimplified: "继续行驶。刹车与加速确定轴向；转弯分辨哪边是前方。"
        ],
        .calibrate: [.english: "Calibrate", .chineseSimplified: "校准"],
        .clearCalibration: [
            .english: "Clear calibration",
            .chineseSimplified: "清除校准"
        ],
        .startFirstForCalibration: [
            .english: "Start MotionCues first — calibration needs live samples.",
            .chineseSimplified: "请先启动 MotionCues——校准需要实时采样。"
        ],
        .fineTuning: [.english: "Fine tuning", .chineseSimplified: "微调"],
        .keepRefining: [
            .english: "Keep refining in the background",
            .chineseSimplified: "在后台持续精炼"
        ],
        .manualAdjustment: [
            .english: "Manual adjustment",
            .chineseSimplified: "手动调整"
        ],
        .fineTuningFooter: [
            .english: "Background refinement absorbs the gyroscope heading drift that Core Motion's magnetometer-free reference frame accumulates (a few degrees a minute), and copes with the phone being nudged. Turn it off if you would rather freeze the calibration exactly as measured.",
            .chineseSimplified: "后台精炼会吸收 Core Motion 无磁力计参考系中陀螺仪航向漂移（大约每分钟几度），也能应对手机被轻推。若希望冻结为实测结果，可关闭此项。"
        ],

        .welcomeBlurb: [
            .english: "Small particles at the edges of the screen move with the car, so what your eyes see matches what your inner ear feels.",
            .chineseSimplified: "屏幕边缘的小粒子随车辆运动，让眼睛看到的与内耳感受到的一致。"
        ],
        .welcomeStep1Title: [
            .english: "Your Mac has no motion sensor",
            .chineseSimplified: "你的 Mac 没有运动传感器"
        ],
        .welcomeStep1Body: [
            .english: "Not a limitation of this app: macOS exposes no accelerometer, and Apple Silicon Macs have no inertial hardware at all. So an iPhone does the sensing and streams it over, a hundred times a second.",
            .chineseSimplified: "不是本应用的限制：macOS 不提供加速度计，Apple Silicon Mac 也没有惯性硬件。因此由 iPhone 感知并以每秒约一百次推流过来。"
        ],
        .welcomeStep2Title: [
            .english: "Install the companion on your iPhone",
            .chineseSimplified: "在 iPhone 上安装配套应用"
        ],
        .welcomeStep2Body: [
            .english: "Build the MotionCuesIOS target onto your phone, open it and tap Start streaming. Your Mac will appear in its list within a second or two.",
            .chineseSimplified: "把 MotionCuesIOS 目标装到手机上，打开后点「开始推流」。一两秒内，列表里就会出现你的 Mac。"
        ],
        .welcomeStep3Title: [
            .english: "Allow the local network",
            .chineseSimplified: "允许本地网络"
        ],
        .welcomeStep3Body: [
            .english: "Both devices will ask once. The link is a direct connection between your own two devices — nothing goes to the Internet, here or ever.",
            .chineseSimplified: "两台设备各会询问一次。链路是你自己两台设备之间的直连——数据不会上互联网，现在不会，以后也不会。"
        ],
        .welcomeStep4Title: [
            .english: "Calibrate on your first journey",
            .chineseSimplified: "第一次出行时校准"
        ],
        .welcomeStep4Body: [
            .english: "Put the phone anywhere it will stay put; orientation does not matter. Press Calibrate and drive normally for about twenty seconds, including at least one bend. MotionCues works out which way the car points from the driving itself.",
            .chineseSimplified: "把手机放在能固定的位置；朝向无关紧要。按下「校准」并正常行驶约二十秒，至少转一次弯。MotionCues 会从行驶本身推算出车头方向。"
        ],
        .welcomeStep5Title: [
            .english: "AirPods will do at a pinch",
            .chineseSimplified: "必要时可用 AirPods"
        ],
        .welcomeStep5Body: [
            .english: "If the phone is not to hand, MotionCues can fall back to head motion from AirPods. It is a real inertial signal, but your head moves too, so treat it as the lesser option.",
            .chineseSimplified: "手机不在手边时，MotionCues 可回退到 AirPods 头部运动。那是真实的惯性信号，但头部也会动，因此当作次优方案。"
        ],
        .iPhoneConnected: [
            .english: "iPhone connected",
            .chineseSimplified: "iPhone 已连接"
        ],
        .waitingForPhone: [
            .english: "Waiting for a phone",
            .chineseSimplified: "正在等待手机"
        ],
        .motionPermissionLabel: [
            .english: "Motion permission: %@",
            .chineseSimplified: "运动权限：%@"
        ],
        .tryWithoutCar: [
            .english: "Try it without a car",
            .chineseSimplified: "无车试用"
        ],

        .advertising: [
            .english: "Advertising %@…",
            .chineseSimplified: "正在广播 %@…"
        ],
        .cannotListen: [
            .english: "Cannot listen: %@",
            .chineseSimplified: "无法监听：%@"
        ],
        .stopped: [.english: "Stopped", .chineseSimplified: "已停止"],
        .waitingForIPhoneOnPort: [
            .english: "Waiting for iPhone on port %d",
            .chineseSimplified: "正在端口 %d 等待 iPhone"
        ],
        .waitingForIPhone: [
            .english: "Waiting for iPhone",
            .chineseSimplified: "正在等待 iPhone"
        ],
        .listenerFailed: [
            .english: "Listener failed: %@",
            .chineseSimplified: "监听失败：%@"
        ],
        .waitingWithError: [
            .english: "Waiting: %@",
            .chineseSimplified: "等待中：%@"
        ],
        .connectedTo: [
            .english: "Connected to %@",
            .chineseSimplified: "已连接到 %@"
        ],
        .connectedPlain: [
            .english: "Connected",
            .chineseSimplified: "已连接"
        ],
        .iPhoneDisconnected: [
            .english: "iPhone disconnected",
            .chineseSimplified: "iPhone 已断开"
        ],
        .noDataFromIPhone: [
            .english: "No data from iPhone",
            .chineseSimplified: "未收到 iPhone 数据"
        ],
        .motionAccessDeniedHeadphones: [
            .english: "Motion access denied — enable it in System Settings › Privacy & Security › Motion & Fitness.",
            .chineseSimplified: "运动访问被拒绝——请在「系统设置 › 隐私与安全性 › 运动与健身」中开启。"
        ],
        .noMotionHeadphones: [
            .english: "No motion-capable headphones connected.",
            .chineseSimplified: "未连接支持运动感应的耳机。"
        ],
        .waitingForHeadphones: [
            .english: "Waiting for headphones…",
            .chineseSimplified: "正在等待耳机…"
        ],
        .airPodsDegraded: [
            .english: "AirPods head motion (degraded source)",
            .chineseSimplified: "AirPods 头部运动（降级来源）"
        ],
        .headphonesDisconnected: [
            .english: "Headphones disconnected.",
            .chineseSimplified: "耳机已断开。"
        ],
        .syntheticDrive: [
            .english: "Synthetic drive",
            .chineseSimplified: "合成驾驶"
        ],

        .startStreaming: [
            .english: "Start streaming",
            .chineseSimplified: "开始推流"
        ],
        .stopStreaming: [
            .english: "Stop streaming",
            .chineseSimplified: "停止推流"
        ],
        .macsFound: [.english: "Macs found", .chineseSimplified: "已发现的 Mac"],
        .keepScreenAwake: [
            .english: "Keep screen awake while streaming",
            .chineseSimplified: "推流时保持屏幕常亮"
        ],
        .useGPSSpeed: [
            .english: "Use GPS speed",
            .chineseSimplified: "使用 GPS 速度"
        ],
        .detectVehicle: [
            .english: "Detect when you're in a vehicle",
            .chineseSimplified: "检测是否在车内"
        ],
        .rightNow: [.english: "Right now", .chineseSimplified: "当前"],
        .speed: [.english: "Speed", .chineseSimplified: "速度"],
        .options: [.english: "Options", .chineseSimplified: "选项"],
        .detectVehicleFooter: [
            .english: "Your Mac hides the cues when this says you're not in a vehicle, so you don't have to remember to switch them off. It uses the motion coprocessor, which costs very little battery.",
            .chineseSimplified: "当这里显示你不在车内时，Mac 会隐藏提示，这样就不必记得手动关闭。它使用运动协处理器，耗电很少。"
        ],
        .packetsSent: [.english: "Packets sent", .chineseSimplified: "已发送数据包"],
        .droppedBackpressure: [
            .english: "Dropped (backpressure)",
            .chineseSimplified: "丢弃（背压）"
        ],
        .link: [.english: "Link", .chineseSimplified: "链路"],
        .linkFooter: [
            .english: "GPS speed lets the Mac compensate for body roll in corners (lateral acceleration ≈ speed × yaw rate). It costs battery, so it is optional. Everything stays on your devices — the link is a direct UDP stream on the local network or over peer-to-peer Wi-Fi, with no Internet involved.",
            .chineseSimplified: "GPS 速度让 Mac 能补偿过弯时的车身侧倾（横向加速度 ≈ 速度 × 偏航角速度）。会耗电，因此可选。一切都留在你的设备上——链路是局域网或点对点 Wi-Fi 上的直连 UDP，不涉及互联网。"
        ],
        .ifWillNotConnect: [
            .english: "If it will not connect",
            .chineseSimplified: "若无法连接"
        ],
        .tipLocalNetwork: [
            .english: "Both devices need Local Network permission. iOS asks the first time; if you said no, turn it back on in Settings › MotionCues.",
            .chineseSimplified: "两台设备都需要「本地网络」权限。iOS 会在首次询问；若当时拒绝了，请到「设置 › MotionCues」重新打开。"
        ],
        .tipMacRunning: [
            .english: "Make sure MotionCues is running on the Mac and set to Automatic or iPhone.",
            .chineseSimplified: "确认 Mac 上 MotionCues 正在运行，且传感器设为「自动」或「iPhone」。"
        ],
        .tipWiFiOn: [
            .english: "No Wi-Fi in the car is fine — leave Wi-Fi switched ON anyway, because peer-to-peer discovery uses the Wi-Fi radio.",
            .chineseSimplified: "车里没有 Wi-Fi 也没关系——请仍保持 Wi-Fi 开启，因为点对点发现要用到 Wi-Fi 射频。"
        ],
        .senderStopped: [.english: "Stopped", .chineseSimplified: "已停止"],
        .lookingForMac: [
            .english: "Looking for a Mac…",
            .chineseSimplified: "正在查找 Mac…"
        ],
        .connectingTo: [
            .english: "Connecting to %@…",
            .chineseSimplified: "正在连接到 %@…"
        ],
        .streamingTo: [
            .english: "Streaming to %@",
            .chineseSimplified: "正在推流到 %@"
        ],
        .problem: [
            .english: "Problem: %@",
            .chineseSimplified: "问题：%@"
        ],
        .macStoppedResponding: [
            .english: "Mac stopped responding",
            .chineseSimplified: "Mac 停止响应"
        ],
        .driveUnknown: [.english: "Unknown", .chineseSimplified: "未知"],
        .driveInVehicle: [
            .english: "In a vehicle",
            .chineseSimplified: "在车内"
        ],
        .driveNotInVehicle: [
            .english: "Not in a vehicle",
            .chineseSimplified: "不在车内"
        ],
        .driveUnavailable: [
            .english: "Not available on this device",
            .chineseSimplified: "此设备不可用"
        ],
        .driveMotionDenied: [
            .english: "Motion access denied",
            .chineseSimplified: "运动访问被拒绝"
        ],
        .deviceMotionUnavailable: [
            .english: "Device motion is not available on this device.",
            .chineseSimplified: "此设备不支持设备运动。"
        ],
        .locationDeniedRoll: [
            .english: "Location denied — lateral roll compensation will be skipped.",
            .chineseSimplified: "定位被拒绝——将跳过横向侧倾补偿。"
        ]
    ]
}
