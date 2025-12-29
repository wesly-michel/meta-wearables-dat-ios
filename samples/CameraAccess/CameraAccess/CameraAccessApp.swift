/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// CameraAccessApp.swift (UPDATED)
//
// Main entry point for the CameraAccess sample app demonstrating the Meta Wearables DAT SDK.
// UPDATED: Added TabView with Translation and Testing modes for optimization.
//

import Foundation
import MWDATCore
import SwiftUI

#if DEBUG
import MWDATMockDevice
#endif

@main
struct CameraAccessApp: App {
  #if DEBUG
  // Debug menu for simulating device connections during development
  @StateObject private var debugMenuViewModel = DebugMenuViewModel(mockDeviceKit: MockDeviceKit.shared)
  #endif
  private let wearables: WearablesInterface
  @StateObject private var wearablesViewModel: WearablesViewModel

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[CameraAccess] Failed to configure Wearables SDK: \(error)")
      #endif
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    self._wearablesViewModel = StateObject(wrappedValue: WearablesViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      // ✅ TabView for switching between Translation, Testing, and Vision modes
      TabView {
        // Tab 1: Main Translation View
        CameraTranslationView()
          .tabItem {
            Label("Translate", systemImage: "camera.fill")
          }
        
        // Tab 2: Model Testing View
        ModelTestingView()
          .tabItem {
            Label("Testing", systemImage: "cpu.fill")
          }
        
        // Tab 3: Continuous Vision Mode
        ContinuousVisionView()
          .tabItem {
            Label("Vision", systemImage: "eye.fill")
          }
      }
      .accentColor(.blue)
      // Error alerts from view model
      .alert("Error", isPresented: $wearablesViewModel.showError) {
        Button("OK") {
          wearablesViewModel.dismissError()
        }
      } message: {
        Text(wearablesViewModel.errorMessage)
      }
      #if DEBUG
      .sheet(isPresented: $debugMenuViewModel.showDebugMenu) {
        MockDeviceKitView(viewModel: debugMenuViewModel.mockDeviceKitViewModel)
      }
      .overlay {
        DebugMenuView(debugMenuViewModel: debugMenuViewModel)
      }
      #endif  // DEBUG

      // Registration view handles the flow for connecting to the glasses via Meta AI
      RegistrationView(viewModel: wearablesViewModel)
    }
  }
}
