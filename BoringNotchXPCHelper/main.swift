//
//  main.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    
    /// This method is where the NSXPCListener configures, accepts, and resumes a new incoming NSXPCConnection.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        
        // Configure the connection.
        // First, set the interface that the exported object implements.
        newConnection.exportedInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
        
        // Next, set the object that the connection exports. All messages sent on the connection to this service will be sent to the exported object to handle. The connection retains the exported object.
        let exportedObject = BoringNotchXPCHelper()
        newConnection.exportedObject = exportedObject

        // Interface for the reverse channel: the helper pushes notification events
        // to the main app via this connection's remoteObjectProxy.
        newConnection.remoteObjectInterface = NSXPCInterface(with: (any NotificationRelayClientProtocol).self)
        NotificationRelayService.shared.connection = newConnection
        newConnection.invalidationHandler = { [weak newConnection] in
            if NotificationRelayService.shared.connection === newConnection {
                NotificationRelayService.shared.connection = nil
            }
        }

        // Resuming the connection allows the system to deliver more incoming messages.
        newConnection.resume()
        
        // Returning true from this method tells the system that you have accepted this connection. If you want to reject the connection for some reason, call invalidate() on the connection and return false.
        return true
    }
}

// Create the delegate for the service.
let delegate = ServiceDelegate()

// 通知中继需要 helper 常驻（AXObserver 状态在进程内）：禁止系统因空闲自动终止本进程。
// 否则 helper 闲置退出后监听静默停止，且主 app 侧已保存的横幅 id 全部失效。
ProcessInfo.processInfo.disableAutomaticTermination("Notification relay keeps long-lived AXObserver state")
ProcessInfo.processInfo.disableSuddenTermination()

// Set up the one NSXPCListener for this service. It will handle all incoming connections.
let listener = NSXPCListener.service()
listener.delegate = delegate

// Resuming the serviceListener starts this service. This method does not return.
listener.resume()
