//
//  NetworkRequest.swift
//  Siesta
//
//  Created by Paul on 2015/12/15.
//  Copyright © 2016 Bust Out Solutions. All rights reserved.
//

import Foundation

//private func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
//  switch (lhs, rhs) {
//  case let (l?, r?):
//    return l < r
//  case (nil, _?):
//    return true
//  default:
//    return false
//  }
//}
//
//private func >= <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
//  switch (lhs, rhs) {
//  case let (l?, r?):
//    return l >= r
//  default:
//    return !(lhs < rhs)
//  }
//}


internal final class NetworkRequest: RequestWithDefaultCallbacks, CustomDebugStringConvertible
    {
    // Basic metadata
    private let resource: Resource
    private let requestDescription: String
    internal var config: Configuration
        { return resource.configuration(forRequest: underlyingRequest) }

    // Networking
    private let requestBuilder: (Void) -> URLRequest
    private let underlyingRequest: URLRequest
    internal var networking: RequestNetworking?  // present only after start()
    internal var underlyingNetworkRequestCompleted = false  // so tests can wait for it to finish

    // Progress
    private var progressTracker: ProgressTracker
    var progress: Double
        { return progressTracker.progress }

    // Result
    private var responseCallbacks = CallbackGroup<ResponseInfo>()
    private var wasCancelled: Bool = false
    var isCompleted: Bool
        {
        DispatchQueue.mainThreadPrecondition()
        return responseCallbacks.completedValue != nil
        }

    // MARK: Managing request

    init(resource: Resource, requestBuilder: @escaping (Void) -> URLRequest)
        {
        self.resource = resource
        self.requestBuilder = requestBuilder  // for repeated()
        self.underlyingRequest = requestBuilder()
        self.requestDescription = debugStr([underlyingRequest.httpMethod, underlyingRequest.url])

        progressTracker = ProgressTracker(isGet: underlyingRequest.httpMethod == "GET")
        }

    func start()
        {
        DispatchQueue.mainThreadPrecondition()

        guard self.networking == nil else
            { fatalError("NetworkRequest.start() called twice") }

        guard !wasCancelled else
            {
            debugLog(.Network, [requestDescription, "will not start because it was already cancelled"])
            underlyingNetworkRequestCompleted = true
            return
            }

        debugLog(.Network, [requestDescription])

        let networking = resource.service.networkingProvider.startRequest(underlyingRequest)
            {
            res, data, err in
            DispatchQueue.main.async
                { self.responseReceived(underlyingResponse: res, body: data, error: err) }
            }
        self.networking = networking

        progressTracker.start(
            networking,
            reportingInterval: config.progressReportingInterval)
        }

    func cancel()
        {
        DispatchQueue.mainThreadPrecondition()

        guard !isCompleted else
            {
            debugLog(.Network, ["cancel() called but request already completed:", requestDescription])
            return
            }

        debugLog(.Network, ["Cancelled", requestDescription])

        networking?.cancel()

        // Prevent start() from have having any effect if it hasn't been called yet
        wasCancelled = true

        broadcastResponse(ResponseInfo.cancellation)
        }

    func repeated() -> Request
        {
        let req = NetworkRequest(resource: resource, requestBuilder: requestBuilder)
        req.start()
        return req
        }

    // MARK: Callbacks

    internal func addResponseCallback(_ callback: ResponseCallback) -> Self
        {
        responseCallbacks.addCallback(callback)
        return self
        }

    func onProgress(_ callback: @escaping (Double) -> Void) -> Self
        {
        progressTracker.callbacks.addCallback(callback)
        return self
        }

    // MARK: Response handling

    // Entry point for response handling. Triggered by RequestNetworking completion callback.
    private func responseReceived(underlyingResponse: HTTPURLResponse?, body: Data?, error: Swift.Error?)
        {
        DispatchQueue.mainThreadPrecondition()

        underlyingNetworkRequestCompleted = true

        debugLog(.Network, [underlyingResponse?.statusCode ?? error, "←", requestDescription])
        debugLog(.NetworkDetails, ["Raw response headers:", underlyingResponse?.allHeaderFields])
        debugLog(.NetworkDetails, ["Raw response body:", body?.count ?? 0, "bytes"])

        let responseInfo = interpretResponse(underlyingResponse, body, error)

        if shouldIgnoreResponse(responseInfo.response)
            { return }

        transformResponse(responseInfo, then: broadcastResponse)
        }

    private func isError(httpStatusCode: Int?) -> Bool
        {
        guard let httpStatusCode = httpStatusCode else
            { return false }
        return httpStatusCode >= 400
        }

    private func interpretResponse(
            _ underlyingResponse: HTTPURLResponse?,
            _ body: Data?,
            _ error: Swift.Error?)
        -> ResponseInfo
        {
        if isError(httpStatusCode: underlyingResponse?.statusCode) || error != nil
            {
            return ResponseInfo(
                response: .failure(Error(
                    response: underlyingResponse,
                    content: body,
                    cause: error)))
            }
        else if underlyingResponse?.statusCode == 304
            {
            if let entity = resource.latestData
                {
                return ResponseInfo(response: .success(entity), isNew: false)
                }
            else
                {
                return ResponseInfo(
                    response: .failure(Error(
                        userMessage: NSLocalizedString("No data available", comment: "userMessage"),
                        cause: Error.Cause.NoLocalDataFor304())))
                }
            }
        else
            {
            return ResponseInfo(response: .success(Entity(response: underlyingResponse, content: body ?? Data())))
            }
        }

    private func transformResponse(
            _ rawInfo: ResponseInfo,
            then afterTransformation: @escaping (ResponseInfo) -> Void)
        {
        let processor = config.pipeline.makeProcessor(rawInfo.response, resource: resource)

        DispatchQueue.global(qos: DispatchQoS.QoSClass.userInitiated).async
            {
            let processedInfo =
                rawInfo.isNew
                    ? ResponseInfo(response: processor(), isNew: true)
                    : rawInfo

            DispatchQueue.main.async
                { afterTransformation(processedInfo) }
            }
        }

    private func broadcastResponse(_ newInfo: ResponseInfo)
        {
        DispatchQueue.mainThreadPrecondition()

        if shouldIgnoreResponse(newInfo.response)
            { return }

        debugLog(.NetworkDetails, ["Response after transformer pipeline:", newInfo.isNew ? " (new data)" : " (data unchanged)", newInfo.response.dump()])

        progressTracker.complete()

        responseCallbacks.notifyOfCompletion(newInfo)
        }

    private func shouldIgnoreResponse(_ newResponse: Response) -> Bool
        {
        guard let existingResponse = responseCallbacks.completedValue?.response else
            { return false }

        // We already received a response; don't broadcast another one.

        if !existingResponse.isCancellation
            {
            debugLog(.Network,
                [
                "WARNING: Received response for request that was already completed:", requestDescription,
                "This may indicate a bug in the NetworkingProvider you are using, or in Siesta.",
                "Please file a bug report: https://github.com/bustoutsolutions/siesta/issues/new",
                "\n    Previously received:", existingResponse,
                "\n    New response:", newResponse
                ])
            }
        else if !newResponse.isCancellation
            {
            // Sometimes the network layer sends a cancellation error. That’s not of interest if we already knew
            // we were cancelled. If we received any other response after cancellation, log that we ignored it.

            debugLog(.NetworkDetails,
                [
                "Received response, but request was already cancelled:", requestDescription,
                "\n    New response:", newResponse
                ])
            }

        return true
        }

    // MARK: Debug

    var debugDescription: String
        {
        return "Siesta.Request:"
            + String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16)
            + "("
            + requestDescription
            + ")"
        }
    }