// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import SwiftUI
import Network
import Pulse

@available(iOS 15, *)
struct RemoteLoggerSelectedDeviceView: View {
    @ObservedObject var logger: RemoteLogger = .shared
    @Binding var selectedServer: RemoteLoggerServerViewModel?

    let name: String
    let server: RemoteLoggerServerViewModel?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                makeStatusView(for: logger.connectionState)
            }
            Spacer()
            if (server?.server.isProtected ?? false) {
                Image(systemName: "lock.fill")
                    .foregroundColor(.separator)
            }
            Menu(content: {
                if let server {
                    Button("Show Details") {
                        self.selectedServer = server
                    }
                    Divider()
                }
                Button("Forget this Device", role: .destructive) {
                    logger.forgetServer(named: name)
                }
            }, label: {
                Image(systemName: "ellipsis.circle")
            })
        }
    }

    private func makeStatusView(for state: RemoteLogger.ConnectionState) -> some View {
        HStack {
            Circle()
                .frame(width: 8, height: 8)
                .foregroundColor(statusColor)
            Text(statusTitle)
                .lineLimit(1)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch logger.connectionState {
        case .connected: return Color.green
        case .connecting:
            if logger.connectionError != nil {
                return Color.red
            } else {
                return Color.yellow
            }
        case .disconnected: return Color.gray
        }
    }

    private var statusTitle: String {
        switch logger.connectionState {
        case .connected: return "Connected"
        case .connecting:
            if let error = logger.connectionError {
                return "Failed: \(error.localizedDescription)"
            } else {
                return "Connecting..."
            }
        case .disconnected: return "Disconnected"
        }
    }
}