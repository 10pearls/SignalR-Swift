//
//  LongPollingTransport.swift
//  SignalR-Swift
//
//  
//  Copyright © 2017 Jordan Camara. All rights reserved.
//

import Foundation
import ObjectMapper
import Alamofire

public class LongPollingTransport: HttpTransport {
    var reconnectDelay = 5.0
    var errorDelay = 2.0
    private var pollingOperationQueue = OperationQueue()

    override init() {
        self.pollingOperationQueue.maxConcurrentOperationCount = 1
    }

    // MARK: - Client Transport Protocol

    override public var name: String? {
        return "longPolling"
    }

    override public var supportsKeepAlive: Bool {
        return false
    }

    override public func negotiate(connection: ConnectionProtocol, connectionData: String, completionHandler: ((NegotiationResponse?, Error?) -> ())?) {
        super.negotiate(connection: connection, connectionData: connectionData, completionHandler: completionHandler)
    }

    override public func start(connection: ConnectionProtocol, connectionData: String, completionHandler: ((Any?, Error?) -> ())?) {
        self.poll(connection: connection, connectionData: connectionData, completionHandler: completionHandler)
    }

    override public func send<T>(connection: ConnectionProtocol, data: T, connectionData: String, completionHandler: ((Any?, Error?) -> ())?) where T : Mappable {
        super.send(connection: connection, data: data, connectionData: connectionData, completionHandler: completionHandler)
    }

    override public func abort(connection: ConnectionProtocol, timeout: Double, connectionData: String) {
        super.abort(connection: connection, timeout: timeout, connectionData: connectionData)
    }

    override public func lostConnection(connection: ConnectionProtocol) {

    }

    // MARK: - Long Polling

    func poll(connection: ConnectionProtocol, connectionData: String?, completionHandler: ((_ response: String?, _ error: Error?) -> ())?) {
        var canReconnect = true

        var url = connection.url
        if connection.messageId == nil {
            url = url.appending("connect")
        } else if self.isConnectionReconnecting(connection: connection) {
            url = url.appending("reconnect")
        } else {
            url = url.appending("poll")
        }

        self.delayConnectionReconnect(connection: connection, canReconnect: &canReconnect)

        var parameters: [String: Any] = [
            "transport": self.name ?? "",
            "connectionToken": connection.connectionToken ?? "",
            "messageId": connection.messageId ?? "",
            "groupsToken": connection.groupsToken ?? "",
            "connectionData": connectionData ?? ""
        ]

        if let queryString = connection.queryString {
            for key in queryString.keys {
                parameters[key] = queryString[key]
            }
        }

        let request = connection.getRequest(url: url, httpMethod: .get, encoding: URLEncoding.queryString, parameters: parameters, timeout: 240)
        request.validate().responseString { [unowned self] (response) in
            switch response.result {
            case .success(let result):

                var shouldReconnect = false
                var disconnectedReceived = false

                connection.processResponse(response: result, shouldReconnect: &shouldReconnect, disconnected: &disconnectedReceived)

                if let handler = completionHandler {
                    handler(nil, nil)
                }

                if self.isConnectionReconnecting(connection: connection) {
                    self.connectionReconnect(connection: connection, canReconnect: canReconnect)
                }

                if shouldReconnect {
                    _ = Connection.ensureReconnecting(connection: connection)
                }

                if disconnectedReceived {
                    connection.disconnect()
                }

                if !self.tryCompleteAbort() {
                    canReconnect = true
                    self.poll(connection: connection, connectionData: connectionData, completionHandler: nil)
                }
            case .failure(let error):
                canReconnect = false

                _ = Connection.ensureReconnecting(connection: connection)

                if !self.tryCompleteAbort() && ExceptionHelper.isRequestAborted(error: (error as NSError)) {
                    connection.didReceiveError(error: error)

                    canReconnect = true

                    _ = BlockOperation(block: { [unowned self] () -> () in
                        self.poll(connection: connection, connectionData: connectionData, completionHandler: nil)
                    }).perform(#selector(BlockOperation.start), with: nil, afterDelay: self.errorDelay)
                } else {
                    self.completeAbort()
                    if let handler = completionHandler {
                        handler(nil, error)
                    }
                }
            }
        }

    }

    func delayConnectionReconnect(connection: ConnectionProtocol, canReconnect: inout Bool) {
        if self.isConnectionReconnecting(connection: connection) {
            let canReconnectCopy = canReconnect
            if canReconnect {
                canReconnect = false

                _ = BlockOperation(block: { [unowned self] () -> () in
                    self.connectionReconnect(connection: connection, canReconnect: canReconnectCopy)
                }).perform(#selector(BlockOperation.start), with: nil, afterDelay: self.reconnectDelay)
            }
        }
    }

    func connectionReconnect(connection: ConnectionProtocol, canReconnect: Bool) {
        if canReconnect {
            if connection.changeState(oldState: .reconnecting, toState: .connected) {
                connection.didReconnect()
            }
        }
    }

    func isConnectionReconnecting(connection: ConnectionProtocol) -> Bool {
        return connection.state == .reconnecting
    }
}
