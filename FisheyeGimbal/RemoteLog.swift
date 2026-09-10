//
//  RemoteLog.swift
//  FisheyeGimbal
//
//  把 App 里的日志实时推到你电脑上，省得在手机上抄。
//
//  实现：UDP 单行数据报，纯 Foundation、零依赖。
//  UDP 比 TCP 合适：手机屏幕小、丢一两行无所谓，但不能因为接收端没开就阻塞渲染线程。
//  发送走独立串行队列，渲染/相机线程只往队列里塞字符串，不阻塞。
//

import Foundation
import Network
import Darwin
import UIKit

final class RemoteLog: ObservableObject {

    static let shared = RemoteLog()

    @Published private(set) var enabled = false
    @Published var host: String = ""
    @Published var port: String = "9876"
    @Published private(set) var sentLines = 0
    @Published private(set) var lastError: String?

    private var socket: Int32 = -1
    private var queue = DispatchQueue(label: "fe.remotelog", qos: .utility)
    private let lock = NSLock()

    private init() {
        host = Self.guessHost()
    }

    /// 猜一个默认目标：本机 WiFi 地址的同一网段，尾号填 1（常见路由器/电脑）
    static func guessHost() -> String {
        guard let ip = localWiFiAddress() else { return "" }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return ip }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    /// 取本机 WiFi 的 IPv4 地址
    static func localWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = first
        while true {
            let iface = ptr.pointee
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                // en0 = WiFi
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let s = String(cString: hostname)
                    if !s.isEmpty { address = s }
                }
            }
            guard let next = iface.ifa_next else { break }
            ptr = next
        }
        return address
    }

    /// 本机 IP（显示用，方便你确认网段）
    static var localIP: String { localWiFiAddress() ?? "未知" }

    func setEnabled(_ on: Bool) {
        if on {
            start()
        } else {
            stop()
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeSocket()
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                DispatchQueue.main.async {
                    self.lastError = "socket() 失败 errno=\(errno)"
                    self.enabled = false
                }
                return
            }
            // 广播许可，方便试 255.255.255.255
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            self.lock.lock()
            self.socket = fd
            self.lock.unlock()
            DispatchQueue.main.async {
                self.enabled = true
                self.lastError = nil
            }
            self.send("=== FisheyeGimbal 日志已接通 ===")
            self.send("本机IP=\(Self.localIP)  目标=\(self.host):\(self.port)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.closeSocket()
            DispatchQueue.main.async {
                self?.enabled = false
            }
        }
    }

    private func closeSocket() {
        lock.lock()
        if socket >= 0 { close(socket); socket = -1 }
        lock.unlock()
    }

    /// 发送一行（可从任意线程调用，不阻塞）
    func send(_ line: String) {
        guard enabled else { return }
        let h = host.trimmingCharacters(in: .whitespaces)
        guard let p = UInt16(port.trimmingCharacters(in: .whitespaces)), !h.isEmpty else { return }
        let payload = Array((line + "\n").utf8)
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.socket
            self.lock.unlock()
            guard fd >= 0 else { return }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = p.bigEndian
            guard inet_pton(AF_INET, h, &addr.sin_addr) == 1 else { return }

            let sent = withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    payload.withUnsafeBufferPointer { buf in
                        sendto(fd, buf.baseAddress, payload.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent > 0 {
                DispatchQueue.main.async { self.sentLines += 1 }
            }
        }
    }

    // MARK: - 便捷封装

    func log(_ tag: String, _ msg: String) {
        send("[\(Self.stamp())] \(tag) \(msg)")
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}
