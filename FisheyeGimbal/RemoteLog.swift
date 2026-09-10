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

    /// 注意：不能叫 socket —— 那会遮蔽 Darwin 的全局函数 socket()，
    /// 编译器会报 "use of 'socket' refers to instance method rather than global function"
    private var socketFD: Int32 = -1
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
        guard Darwin.getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { Darwin.freeifaddrs(ifaddr) }
        var ptr = first
        while true {
            let iface = ptr.pointee
            guard let ifaAddr = iface.ifa_addr else { break }
            let family = ifaAddr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                // en0 = WiFi
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    Darwin.getnameinfo(ifaAddr, socklen_t(ifaAddr.pointee.sa_len),
                                       &hostname, socklen_t(hostname.count),
                                       nil, 0, NI_NUMERICHOST)
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

    /// 目标地址列表：始终包含广播地址（开机即发，不需要知道电脑 IP），
    /// 如果用户另外填了具体 IP，再多发一份过去。
    private var targets: [String] {
        var list = ["255.255.255.255"]
        let h = host.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty && h != "255.255.255.255" { list.append(h) }
        return list
    }

    private var resolvedPort: UInt16 {
        UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 9876
    }

    /// 开机即调：建 socket + 自动广播，不需要用户做任何事
    @discardableResult
    func autoStart() -> Bool {
        if !enabled { start() }
        return enabled
    }

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeSocket()
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                DispatchQueue.main.async {
                    self.lastError = "socket() 失败 errno=\(Darwin.errno)"
                    self.enabled = false
                }
                return
            }
            // 广播许可：255.255.255.255 必需
            var on: Int32 = 1
            Darwin.setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            self.lock.lock()
            self.socketFD = fd
            self.lock.unlock()
            DispatchQueue.main.async {
                self.enabled = true
                self.lastError = nil
            }
            self.log("APP", "日志通道已建（广播模式，电脑上跑 listen-log.ps1 即可）")
            self.log("APP", "手机WiFi=\(Self.localIP)  端口=\(self.port)  指定目标=\(self.host.isEmpty ? "无(纯广播)" : self.host)")
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
        if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
        lock.unlock()
    }

    /// 发送一行（可从任意线程调用，不阻塞）。
    /// 同时发往广播地址 + 用户指定的具体 IP。
    func send(_ line: String) {
        guard enabled else { return }
        let p = resolvedPort
        let list = targets
        guard !list.isEmpty else { return }
        let payload = Array((line + "\n").utf8)

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let fd = self.socketFD
            self.lock.unlock()
            guard fd >= 0 else { return }

            for h in list {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = p.bigEndian
                guard Darwin.inet_pton(AF_INET, h, &addr.sin_addr) == 1 else { continue }

                let sent = withUnsafePointer(to: &addr) { ptr -> Int in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        payload.withUnsafeBufferPointer { buf in
                            Darwin.sendto(fd, buf.baseAddress, payload.count, 0, sa,
                                          socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if sent > 0 {
                    DispatchQueue.main.async { self.sentLines += 1 }
                }
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
