//
//  Buffer.swift
//  RxSwift
//
//  Created by Krunoslav Zaher on 9/13/15.
//  Copyright © 2015 Krunoslav Zaher. All rights reserved.
//

extension ObservableType {

    /**
     Projects each element of an observable sequence into a buffer that's sent out when either it's full or a given amount of time has elapsed, using the specified scheduler to run timers.

     A useful real-world analogy of this overload is the behavior of a ferry leaving the dock when all seats are taken, or at the scheduled time of departure, whichever event occurs first.

     - seealso: [buffer operator on reactivex.io](http://reactivex.io/documentation/operators/buffer.html)

     - parameter timeSpan: Maximum time length of a buffer.
     - parameter count: Maximum element count of a buffer.
     - parameter scheduler: Scheduler to run buffering timers on.
     - returns: An observable sequence of buffers.
     */
    public func buffer(timeSpan: RxTimeInterval, count: Int, scheduler: SchedulerType)
        -> Observable<[Element]> {
        return BufferTimeCount(source: self.asObservable(), timeSpan: timeSpan, count: count, scheduler: scheduler)
    }
}

final private class BufferTimeCount<Element>: Producer<[Element]> {
    
    fileprivate let _timeSpan: RxTimeInterval
    fileprivate let _count: Int
    fileprivate let _scheduler: SchedulerType
    fileprivate let _source: Observable<Element>
    
    init(source: Observable<Element>, timeSpan: RxTimeInterval, count: Int, scheduler: SchedulerType) {
        self._source = source
        self._timeSpan = timeSpan
        self._count = count
        self._scheduler = scheduler
    }
    
    override func run<Observer: ObserverType>(_ observer: Observer, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where Observer.Element == [Element] {
        let sink = BufferTimeCountSink(parent: self, observer: observer, cancel: cancel)
        let subscription = sink.run()
        return (sink: sink, subscription: subscription)
    }
}

final private class BufferTimeCountSink<Element, Observer: ObserverType>
    : Sink<Observer>
    , LockOwnerType
    , ObserverType
    , SynchronizedOnType where Observer.Element == [Element] {
    typealias Parent = BufferTimeCount<Element>
    
    private let _parent: Parent
    
    let _lock = RecursiveLock()
    
    // state
    private let _timerD = SerialDisposable()
    private var _buffer = [Element]()
    private var _windowID = 0
    
    init(parent: Parent, observer: Observer, cancel: Cancelable) {
        self._parent = parent
        super.init(observer: observer, cancel: cancel)
    }
 
    func run() -> Disposable {
        self.createTimer(self._windowID)
        return Disposables.create(_timerD, _parent._source.subscribe(self))
    }
    
    func startNewWindowAndSendCurrentOne() {
        self._windowID = self._windowID &+ 1
        let windowID = self._windowID
        
        let buffer = self._buffer
        self._buffer = []
        self.forwardOn(.next(buffer))
        
        self.createTimer(windowID)
    }
    
    func on(_ event: Event<Element>) {
        self.synchronizedOn(event)
    }

    func _synchronized_on(_ event: Event<Element>) {
        switch event {
        case .next(let element):
            self._buffer.append(element)
            
            if self._buffer.count == self._parent._count {
                self.startNewWindowAndSendCurrentOne()
            }
            
        case .error(let error):
            self._buffer = []
            self.forwardOn(.error(error))
            self.dispose()
        case .completed:
            self.forwardOn(.next(self._buffer))
            self.forwardOn(.completed)
            self.dispose()
        }
    }
    
    func createTimer(_ windowID: Int) {
        if self._timerD.isDisposed {
            return
        }
        
        if self._windowID != windowID {
            return
        }

        let nextTimer = SingleAssignmentDisposable()
        
        self._timerD.disposable = nextTimer

        let disposable = self._parent._scheduler.scheduleRelative(windowID, dueTime: self._parent._timeSpan) { previousWindowID in
            self._lock.performLocked {
                if previousWindowID != self._windowID {
                    return
                }
             
                self.startNewWindowAndSendCurrentOne()
            }
            
            return Disposables.create()
        }

        nextTimer.setDisposable(disposable)
    }
}

extension ObservableType {
    
    /**
     Projects each element of an observable sequence info a buffer that's sent out when the boundary Observable emits a .next event or a .complete event, if the accumulated buffer's count
     is over zero.
     
     - seealso: [buffer operator on reactivex.io](http://reactivex.io/documentation/operators/buffer.html)
     
     - parameter boundary: Observable that will act as a boundary between each window.
     - returns: An observable sequence of buffers.
     */
    public func buffer<BoundaryElement>(boundary: Observable<BoundaryElement>) -> Observable<[E]> {
        return BufferBoundary(source: self.asObservable(), boundary: boundary)
    }
    
    /**
     Projects each element of an observable sequence info a buffer that's sent out when the boundary Observable emits a .next event or a .complete event, if the accumulated buffer's count
     is over zero.
     
     A useful real-world example of this is when you have a resource that needs to be updated depending on some asynchronous tasks and you want to accumulate all of those tasks's results
     and just PUT/PATCH the remote resource once per batch of results instead of once per result.
     
     - seealso: [buffer operator on reactivex.io](http://reactivex.io/documentation/operators/buffer.html)
     
     - parameter debounce: Amount of time to debounce the source as the boundary between each window.
     - parameter scheduler: Scheduler to run debouncing on.
     - returns: An observable sequence of buffers.
     */
    public func buffer(debounce: RxTimeInterval, scheduler: SchedulerType) -> Observable<[E]> {
        let shared = self.share()
        return shared.buffer(boundary: shared.debounce(debounce, scheduler: scheduler))
    }
}

final fileprivate class BufferBoundary<Element, BoundaryElement> : Producer<[Element]> {
    
    fileprivate let _source: Observable<Element>
    fileprivate let _boundary: Observable<BoundaryElement>
    
    init(source: Observable<Element>, boundary: Observable<BoundaryElement>) {
        _source = source
        _boundary = boundary
    }
    
    override func run<O : ObserverType>(_ observer: O, cancel: Cancelable) -> (sink: Disposable, subscription: Disposable) where O.E == [Element] {
        let sink = BufferBoundarySink(parent: self, observer: observer, cancel: cancel)
        let subscription = sink.run()
        return (sink: sink, subscription: subscription)
    }
}

final fileprivate class BufferBoundarySink<Element, BoundaryElement, O: ObserverType>
    : Sink<O>
    , LockOwnerType
    , ObserverType
    , SynchronizedOnType where O.E == [Element] {
    typealias Parent = BufferBoundary<Element, BoundaryElement>
    typealias E = Element
    
    private let _parent: Parent
    
    let _lock = RecursiveLock()
    
    // state
    private let _serialDisposable = SerialDisposable()
    private var _buffer = [E]()
    
    init(parent: Parent, observer: O, cancel: Cancelable) {
        _parent = parent
        super.init(observer: observer, cancel: cancel)
    }
    
    func run() -> Disposable {
        let disposable = SingleAssignmentDisposable()
        _serialDisposable.disposable = disposable
        disposable.setDisposable(_parent._boundary.subscribe { (event: Event<BoundaryElement>) in
            switch event {
            case .next(_):
                self.startNewWindowAndSendCurrentOne()
                break
            case .error(let error):
                self._buffer = []
                self.forwardOn(.error(error))
                self.dispose()
                break
            case .completed:
                if self._buffer.count > 0 {
                    self.forwardOn(.next(self._buffer))
                }
                self.forwardOn(.completed)
                self.dispose()
                break
            }
        })
        
        return Disposables.create(_serialDisposable, _parent._source.subscribe(self))
    }
    
    func startNewWindowAndSendCurrentOne() {
        let buffer = _buffer
        _buffer = []
        if buffer.count > 0 {
            forwardOn(.next(buffer))
        }
    }
    
    func on(_ event: Event<E>) {
        synchronizedOn(event)
    }
    
    func _synchronized_on(_ event: Event<Element>) {
        switch event {
        case .next(let element):
            _buffer.append(element)
        case .error(let error):
            _buffer = []
            forwardOn(.error(error))
            dispose()
        case .completed:
            if _buffer.count > 0 {
                forwardOn(.next(_buffer))
            }
            forwardOn(.completed)
            dispose()
        }
    }
}
