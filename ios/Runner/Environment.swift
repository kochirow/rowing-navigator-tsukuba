//
//  Environment.swift
//  Runner
//
//  Created by 大羽俊輔 on 2024/06/08.
//

import Foundation

struct Env {
    static var googleMapApiKey: String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "GMSApiKey") as? String,
            !value.isEmpty,
            !value.contains("$(")
        else {
            return nil
        }
        return value
    }
}
