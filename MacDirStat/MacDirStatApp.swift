//
//  MacDirStatApp.swift
//  MacDirStat
//
//  Created by tushar sariya on 2026-03-26.
//

import SwiftUI

@main
struct MacDirStatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1250, height: 780)
        .commands { DiskCommands() }
    }
}
