//
//  AppLanguage.swift
//
//  In-app language preference. Independent of the system language so the user
//  can switch English ↔ 中文 inside Settings without leaving the app.
//

import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case english = "en"
    case chineseSimplified = "zh-Hans"

    public var id: String { rawValue }

    /// Shown in the language picker itself — always in the language's own name.
    public var menuTitle: String {
        switch self {
        case .english: "English"
        case .chineseSimplified: "中文"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    public static let defaultsKey = "preferredLanguage"

    public static let didChangeNotification = Notification.Name("com.motioncues.languageDidChange")

    /// Reads the persisted choice. Missing or unknown values mean English.
    public static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let language = AppLanguage(rawValue: raw) else {
            return .english
        }
        return language
    }

    public static func persist(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: language)
    }
}
