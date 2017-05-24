//
//  Connection.swift
//  SignalR-Swift
//
//  
//  Copyright © 2017 Jordan Camara. All rights reserved.
//

import Foundation
import UIKit
import Alamofire
import ObjectMapper

public typealias ConnectionStartedClosure = (() -> ())
public typealias ConnectionReceivedClosure = ((Any) -> ())
public typealias ConnectionErrorClosure = ((Error) -> ())
public typealias ConnectionClosedClosure = (() -> ())
public typealias ConnectionReconnectingClosure = (() -> ())
public typealias ConnectionReconnectedClosure = (() -> ())
public typealias ConnectionStateChangedClosure = ((ConnectionState) -> ())
public typealias ConnectionConnectionSlowClosure = (() -> ())

public class Connection: ConnectionProtocol {
    var defaultAbortTimeout = 30.0
    var assemblyVersion: Version?
    var disconnectTimeout: Double?
    var disconnectTimeoutOperation: BlockOperation!

    public var state = ConnectionState.disconnected
    public var url: String

    public var items = [String : Any]()
    public let queryString: [String: String]?

    var connectionData: String?
    var monitor: HeartbeatMonitor?

    public var version = Version(major: 1, minor: 3)

    public var connectionId: String?
    public var connectionToken: String?
    public var groupsToken: String?
    public var messageId: String?

    public var headers = HTTPHeaders()
    public var keepAliveData: KeepAliveData?

    public var transport: ClientTransportProtocol?
    public var transportConnectTimeout = 0.0

    public var started: ConnectionStartedClosure?
    public var received: ConnectionReceivedClosure?
    public var error: ConnectionErrorClosure?
    public var closed: ConnectionClosedClosure?
    public var reconnecting: ConnectionReconnectingClosure?
    public var reconnected: ConnectionReconnectedClosure?
    public var stateChanged: ConnectionStateChangedClosure?
    public var connectionSlow: ConnectionConnectionSlowClosure?

    weak var delegate: ConnectionDelegate?

    public static func connection(withUrl url: String) -> Connection {
        return Connection(withUrl: url)
    }

    public static func connection(withUrl url: String, queryString: [String: String]?) -> Connection {
        return Connection(withUrl: url, queryString: queryString)
    }

    static func ensureReconnecting(connection: ConnectionProtocol?) -> Bool {
        if connection == nil {
            return false
        }

        if connection!.changeState(oldState: .connected, toState: .reconnecting) {
            connection!.willReconnect()
        }

        return connection!.state == .reconnecting
    }

    public init(withUrl url: String) {
        self.url = url.hasSuffix("/") ? url : url.appending("/")
        self.queryString = nil
    }

    public init(withUrl url: String, queryString: [String: String]?) {
        self.url = url.hasSuffix("/") ? url : url.appending("/")
        self.queryString = queryString
    }

    // MARK: - Connection management

    public func start() {
        self.start(transport: AutoTransport())
    }

    public func start(transport: ClientTransportProtocol) {
        if !self.changeState(oldState: .disconnected, toState: .connecting) {
            return
        }

        self.monitor = HeartbeatMonitor(withConnection: self)
        self.transport = transport

        self.negotiate(transport: transport)
    }

    func negotiate(transport: ClientTransportProtocol) {
        self.connectionData = self.onSending()

        transport.negotiate(connection: self, connectionData: self.connectionData, completionHandler: { [unowned self] (response, error) in
            if error == nil {
                self.verifyProtocolVersion(versionString: response?.protocolVersion)

                self.connectionId = response?.connectionId
                self.connectionToken = response?.connectionToken
                self.disconnectTimeout = response?.disconnectTimeout

                if let transportTimeout = response?.transportConnectTimeout {
                    self.transportConnectTimeout += transportTimeout
                }

                if let keepAlive = response?.keepAliveTimeout {
                    self.keepAliveData = KeepAliveData(timeout: keepAlive)
                }

                self.startTransport()
            } else if let error = error {
                self.didReceiveError(error: error)
                self.stopButDoNotCallServer()
            }
        })
    }

    func startTransport() {
        self.transport?.start(connection: self, connectionData: self.connectionData, completionHandler: { [unowned self] (response, error) in
            if error == nil {
                _ = self.changeState(oldState: .connecting, toState: .connected)

                if let _ = self.keepAliveData, let transport = self.transport, transport.supportsKeepAlive {
                    self.monitor?.start()
                }

                if let started = self.started {
                    started()
                }

                self.delegate?.connectionDidOpen(connection: self)
            } else if let error = error {
                self.didReceiveError(error: error)
                self.stopButDoNotCallServer()
            }
        })
    }

    public func changeState(oldState: ConnectionState, toState newState: ConnectionState) -> Bool {
        if self.state == oldState {
            self.state = newState

            if let stateChanged = self.stateChanged {
                stateChanged(self.state)
            }

            self.delegate?.connection(connection: self, didChangeState: oldState, newState: newState)

            return true
        }

        // invalid transition
        return false
    }

    func verifyProtocolVersion(versionString: String?) {
        var version: Version?

        if versionString == nil || versionString!.isEmpty || !Version.parse(input: versionString, forVersion: &version) || version != self.version {
            NSException.raise(.internalInconsistencyException, format: NSLocalizedString("Incompatible Protocol Version", comment: "internal inconsistency exception"), arguments: getVaList(["nil"]))
        }
    }

    func stopAndCallServer() {
        self.stop(withTimeout: self.defaultAbortTimeout)
    }

    func stopButDoNotCallServer() {
        self.stop(withTimeout: -1.0)
    }

    public func stop() {
        self.stopAndCallServer()
    }

    func stop(withTimeout timeout: Double) {
        if self.state != .disconnected {

            self.monitor?.stop()
            self.monitor = nil

            self.transport?.abort(connection: self, timeout: timeout, connectionData: self.connectionData)
            self.disconnect()

            self.transport = nil
        }
    }

    public func disconnect() {
        if self.state != .disconnected {
            self.state = .disconnected

            self.monitor?.stop()
            self.monitor = nil

            // clear the state for this connection
            self.connectionId = nil
            self.connectionToken = nil
            self.groupsToken = nil
            self.messageId = nil

            self.didClose()
        }
    }

    // MARK: - Sending Data

    public func onSending() -> String? {
        return nil
    }

    public func send(object: Any, completionHandler: ((Any?, Error?) -> ())?) {
        if self.state == .disconnected {
            let userInfo = [
                NSLocalizedFailureReasonErrorKey: NSExceptionName.internalInconsistencyException.rawValue,
                NSLocalizedDescriptionKey: NSLocalizedString("Start must be called before data can be sent.", comment: "start order exception")
            ]

            let error = NSError(domain: "com.autosoftdms.SignalR-Swift.\(type(of: self))", code: 0, userInfo: userInfo)
            self.didReceiveError(error: error)
            if let handler = completionHandler {
                handler(nil, error)
            }

            return
        }

        if self.state == .connecting {
            let userInfo = [
                NSLocalizedFailureReasonErrorKey: NSExceptionName.internalInconsistencyException.rawValue,
                NSLocalizedDescriptionKey: NSLocalizedString("The connection has not been established.", comment: "connection not established exception")
            ]

            let error = NSError(domain: "com.autosoftdms.SignalR-Swift.\(type(of: self))", code: 0, userInfo: userInfo)
            self.didReceiveError(error: error)
            if let handler = completionHandler {
                handler(nil, error)
            }
            return
        }

        self.transport?.send(connection: self, data: object, connectionData: self.connectionData, completionHandler: completionHandler)
    }

    // MARK: - Received Data

    public func didReceiveData(data: Any) {
        if let received = self.received {
            received(data)
        }

        self.delegate?.connection(connection: self, didReceiveData: data)
    }

    public func didReceiveError(error: Error) {
        if let errorClosure = self.error {
            errorClosure(error)
        }

        self.delegate?.connection(connection: self, didReceiveError: error)
    }

    public func willReconnect() {
        self.disconnectTimeoutOperation = BlockOperation(block: { [unowned self] in
            self.stopButDoNotCallServer()
        })

        if let disconnectTimeout = self.disconnectTimeout {
            self.disconnectTimeoutOperation.perform(#selector(BlockOperation.start), with: nil, afterDelay: disconnectTimeout)
        }

        if let reconnecting = self.reconnecting {
            reconnecting()
        }

        self.delegate?.connectionWillReconnect(connection: self)
    }

    public func didReconnect() {
        NSObject.cancelPreviousPerformRequests(withTarget: self.disconnectTimeoutOperation, selector: #selector(BlockOperation.start), object: nil)

        self.disconnectTimeoutOperation = nil

        if let reconnected = self.reconnected {
            reconnected()
        }

        self.delegate?.connectionDidReconnect(connection: self)

        self.updateLastKeepAlive()
    }

    public func connectionDidSlow() {
        if let connectionSlow = self.connectionSlow {
            connectionSlow()
        }

        self.delegate?.connectionDidSlow(connection: self)
    }

    func didClose() {
        if let closed = self.closed {
            closed()
        }

        self.delegate?.connectionDidClose(connection: self)
    }

    // MARK: - Prepare Request

    func addValue(value: String, forHttpHeaderField field: String) {
        self.headers[field] = value
    }

    public func updateLastKeepAlive() {
        if let keepAlive = self.keepAliveData {
            keepAlive.lastKeepAlive = Date()
        }
    }

    public func getRequest(url: URLConvertible, httpMethod: HTTPMethod, encoding: ParameterEncoding, parameters: Parameters?) -> DataRequest {
        return self.getRequest(url: url, httpMethod: httpMethod, encoding: encoding, parameters: parameters, timeout: 30.0)
    }

    public func getRequest(url: URLConvertible, httpMethod: HTTPMethod, encoding: ParameterEncoding, parameters: Parameters?, timeout: Double) -> DataRequest {
        self.headers["User-Agent"] = self.createUserAgentString(client: "SignalR.Client.iOS")

        var urlRequest = try? URLRequest(url: url.asURL(), method: httpMethod, headers: self.headers)
        urlRequest?.timeoutInterval = timeout

        let encodedURLRequest = try? encoding.encode(urlRequest!, with: parameters)
        return Alamofire.request(encodedURLRequest!)
    }

    func createUserAgentString(client: String) -> String {
        if self.assemblyVersion == nil {
            self.assemblyVersion = Version(major: 2, minor: 0)
        }

        return "\(client)/\(self.assemblyVersion!) (\(UIDevice.current.localizedModel) \(UIDevice.current.systemVersion))"
    }

    public func processResponse(response: Any?, shouldReconnect: inout Bool, disconnected: inout Bool) {
        self.updateLastKeepAlive()

        shouldReconnect = false
        disconnected = false

        if response == nil {
            return
        }

        if let responseDict = response as? [String: Any], let message = ReceivedMessage(JSON: responseDict) {
            if let _ = message.result {
                self.didReceiveData(data: responseDict)
            }

            if let reconnect = message.shouldReconnect {
                shouldReconnect = reconnect
            }

            if let disconnect = message.disconnected, disconnected {
                disconnected = disconnect
                return
            }

            if let groupsToken = message.groupsToken {
                self.groupsToken = groupsToken
            }

            if let messages = message.messages {
                if let messageId = message.messageId {
                    self.messageId = messageId
                }

                for message in messages {
                    self.didReceiveData(data: message)
                }
            }
        }
    }
    
    deinit {
        if self.state != .disconnected {
            self.stop()
        }
    }
}
