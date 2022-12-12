/** Provides a channel/range style observer framework.

	Observables provide a similar functionality to `Signal`, but they are
	composable and provide a sequential subscriber API. Their API is also
	`nothrow` for the most part, so that the subscriber side cannot interfere
	with the side that emits events.

	Copyright: Copyright © 2020-2021 Sönke Ludwig
	Authors: Sönke Ludwig
*/
module observable.observable;

import observable.signal : Signal, SignalConnection;

import core.time : Duration;
import std.meta : allSatisfy, staticMap;
import std.typecons : RefCounted, RefCountedAutoInitialize, refCounted;
import taggedalgebraic.taggedunion;
import vibe.core.log : logException;
import vibe.core.sync : LocalManualEvent, createManualEvent;
import vibe.internal.array : FixedRingBuffer;


///
unittest {
	import vibe.core.core : runTask, sleep;
	import core.time : msecs;

	ObservableSource!int source;

	auto t1 = runTask({
		try {
			auto observer = source
				.subscribe();

			assert(observer.consumeOne == 1);
			assert(observer.consumeOne == 2);
			assert(observer.consumeOne == 3);
			assert(observer.empty);
		} catch (Exception e) assert(false, e.toString);
	});

	auto t2 = runTask({
		try {
			auto observer = source
				.map!(i => i * 2)
				.subscribe();

			assert(observer.consumeOne == 2);
			assert(observer.consumeOne == 4);
			assert(observer.consumeOne == 6);
			assert(observer.empty);
		} catch (Exception e) assert(false, e.msg);
	});

	// quick and dirty wait to let the tasks subscribe
	sleep(10.msecs);

	source.put(1);
	source.put(2);
	source.put(3);
	source.close();

	t1.join();
	t2.join();
}

// basic operation should be nothrow
nothrow unittest {
	ObservableSource!int source;
	auto observer = source.subscribe();
	int r;
	source.put(1);
	source.close();
	assert(observer.tryConsumeOne(r));
	assert(r == 1);
	assert(!observer.tryConsumeOne(r));
	assert(source.closed);
	assert(observer.empty);
}


/** Creates an observer for the specified observable.

	An observer returns the events emitted by the observable in a sequential,
	blocking manner. Usually, a separate task is used to drain the observer to
	ensure sequential processing with no concurrency/race-conditions.
*/
Observer!(ObservableType!O) subscribe(O)(auto ref O observable)
	if (isObservable!O)
{
	Observer!(ObservableType!O) ret;
	ret.initialize(observable);
	return ret;
}

unittest { // test non-copyable observable
	static struct MyObservable {
		alias Event = ObservedEvent!int;
		private Signal!Event m_signal;
		void connect(C, ARGS...)(ref SignalConnection conn, C c, ARGS args)
		nothrow {
			m_signal.socket.connect(conn, c, args);
		}
		@disable this(this);
	}

	MyObservable mo;
	auto o = mo.subscribe();
	mo.m_signal.emit(MyObservable.Event(1));
	assert(o.consumeOne == 1);
}


/** Determines whether a type qualifies as an observable.

	An observable must have the following members:

	$(UL
		$(LI `Event`: the type of the events emitted by the observer - this must
			be an instance of `ObservedEvent`)
		$(LI `connect(C, A...)(ref SignalConnection, C callable, A args): Used
			by observers and operators to get notfied of new events emitted by
			an observer)
		$(LI `closed`: A boolean property that signifies whether the observable
			has been closed (cannot emit any more events))
	)
*/
enum isObservable(O) =
	is(O.Event)
	&& __traits(compiles, (SignalConnection c) { O.init
		.connect(c, delegate(O.Event itm, int, int, int) {}, 1, 2, 3); });

static assert(isObservable!(Observable!int));
static assert(isObservable!(ObservableSource!int));

/** Extracts the event tyoe of an observable.
*/
alias ObservableType(O) = typeof(O.Event.init.eventValue);


/** The fundamental source for generating observable events.

	This is the type used to manually generate events using the `put` method.
	The events can be observed using the `Observable` returned by the
	`observable` property.
*/
struct ObservableSource(T, EXTRA_STORAGE = void) {
	private {
		Observable!(T, EXTRA_STORAGE) m_observable;
	}

	alias Event = Observable!(T, EXTRA_STORAGE).Event;

	@disable this(this);
	this(ref return scope ObservableSource rhs) { this.tupleof = rhs.tupleof; }

	@property ref inout(Observable!(T, EXTRA_STORAGE)) observable() inout { return m_observable; }

	alias observable this;

	/** Closes the observable.

		In the closed state, `put` may no longer be called and all subscribed
		observers will receive a notification that no more events will be
		emitted.
	*/
	void close() { m_observable.close(); }

	/** Emits an event.

		All subscribed observers will receive a copy of the event.
	*/
	void put(T event) { m_observable.put(event); }

	static if (!is(EXTRA_STORAGE == void)) {
		@property ref EXTRA_STORAGE extraStorage() { return m_observable.extraStorage; }
	}
}

/** A basic observable.

	This is the observable provided by `ObservableSource` and some of the
	observer modifier functions. Instead of `ObservableSource` an `Observable`
	should usually be made accessible by external code, in order to avoid the
	possibility of injecting events from the outside.
*/
struct Observable(T, EXTRA_STORAGE = void)
{
	alias Event = ObservedEvent!T;

	private static struct Payload {
		Signal!Event signal;
		bool closed;
		static if (!is(EXTRA_STORAGE == void))
			EXTRA_STORAGE extraStorage;

		@disable this(this);
		this(ref return scope Payload rhs) { this.tupleof = rhs.tupleof; }

		~this()
		{
			close();
		}

		void close()
		{
			if (this.closed) return;

			this.closed = true;
			this.signal.emit(Event.close());
		}
	}

	alias PayloadRef = RefCounted!(Payload, RefCountedAutoInitialize.no);

	private {
		PayloadRef m_payload;
	}

	@disable this(this);
	this(ref return scope Observable rhs)
	{
		rhs.initialize();
		m_payload = rhs.m_payload;
	}

	@property bool closed() const { return m_payload.refCountedStore.isInitialized && m_payload.closed; }

	void connect(C, ARGS...)(ref SignalConnection connection, C callable, ARGS args)
		if (is(typeof(callable(Event.init, args))))
	{
		static assert(__traits(compiles, () nothrow { callable(Event.init, args); }),
			"Observable connection callback must be nothrow.");

		initialize();
		if (this.closed) callable(Event.close(), args);
		else m_payload.signal.socket.connect(connection, callable, args);
	}

	static if (!is(EXTRA_STORAGE == void)) {
		private @property ref EXTRA_STORAGE extraStorage()
		{
			initialize();
			return m_payload.extraStorage;
		}
	}

	private void close()
	{
		initialize();
		m_payload.close();
	}

	private void put(T event)
	{
		assert(!this.closed, "Calling Observable.put() on a closed observable.");

		initialize();
		m_payload.signal.emit(Event.event(event));
	}

	private void initialize()
	{
		m_payload.refCountedStore.ensureInitialized();
	}
}

template ObservedEvent(T)
{
	import std.meta : AliasSeq;

	enum has_nothrow_postblit = __traits(compiles, () nothrow {
		T a = T.init;
		T b = T.init;
		a = b;
	});

	static if (has_nothrow_postblit) alias A = AliasSeq!(forceNothrowPostblit);
	else alias A = AliasSeq!();

	@A
	struct U {
		T event;
		Void close;
	}

	alias ObservedEvent = TaggedUnion!U;
}


/** An observer tied to a specific observable.

	This type provides a channel and an input range interface to enable
	sequential consumption of events emitted by an observer.
*/
struct Observer(T)
{
	private static struct Payload {
		FixedRingBuffer!T buffer;
		bool closed;
		LocalManualEvent event;
		SignalConnection conn;

		void put(ObservedEvent!T itm)
		{
			import std.algorithm.comparison : max;

			if (closed) return;

			if (itm.isClose) closed = true;
			else {
				if (buffer.full)
					buffer.capacity = max(16, buffer.capacity * 3 / 2);
				buffer.put(itm.eventValue);
			}

			event.emit();
		}
	}

	private alias Event = ObservedEvent!T;
	private alias PayloadRef = RefCounted!(Payload, RefCountedAutoInitialize.no);

	private {
		PayloadRef m_payload;
	}

	/** Determines whether there are any events left.

		Note that this property needs to wait until either at least one event
		is available, or until the observer was closed.
	*/
	@property bool empty()
	{
		auto ec = m_payload.event.emitCount;

		while (m_payload.buffer.empty) {
			if (m_payload.closed) return true;
			ec = m_payload.event.waitUninterruptible(ec);
		}

		return false;
	}

	/** Determines whether any more events are currently pending.

		This property is `true` *iff* an event is immediately available, i.e.
		that `front` yields a value without waiting. Note that `empty` is
		guaranteed to return `false` in this case.
	*/
	@property bool pending()
	const {
		return m_payload.buffer.length >= 1;
	}

	/** Input range `front` property.

		The caller must make sure that there is actually still an element
		available before invoking this property, either by evaluating `empty`,
		or by external knowledge. Failing to do so will result in an abnormal
		program termination.
	*/
	@property ref T front()
	{
		if (this.empty) assert(false, "Calling .front on an empty subscriber");
		return m_payload.buffer.front;
	}

	/** Input range `popFront` method.

		The caller must make sure that there is actually still an element
		available before invoking this method, either by evaluating `empty`,
		or by external knowledge. Failing to do so will result in an abnormal
		program termination.
	*/
	void popFront()
	{
		if (this.empty) assert(false, "Calling .popFront on an empty subscriber");
		m_payload.buffer.popFront();
	}

	/** Reads a single event.

		Throws: If the observer is closed and all events have been read,
			`ObserverClosedException` will be thrown.
	*/
	T consumeOne()
	{
		T ret;
		if (!tryConsumeOne(ret))
			throw new ObserverClosedException;
		return ret;
	}

	/** Attempts to read a single event.

		Returns: `true` is returned if an event was successfully read. Otherwise
			a value of `false` is returned, which means that the observable
			was closed and no more events are available.
	*/
	bool tryConsumeOne(ref T dst)
	{
		import std.algorithm.mutation : swap;

		if (this.empty) return false;

		swap(dst, m_payload.buffer.front);
		m_payload.buffer.popFront();
		return true;
	}

	private void initialize(O)(ref O observable)
	{
		assert(!m_payload.refCountedStore.isInitialized, "Double-initializing observer!?");
		m_payload.refCountedStore.ensureInitialized();
		m_payload.event = createManualEvent();
		observable.connect(m_payload.conn, &m_payload.put);
	}
}

unittest {
	ObservableSource!int o;
	auto obs = o.subscribe();
	assert(!obs.pending);
	o.put(1);
	assert(obs.front == 1);
	assert(obs.pending);
	assert(!obs.empty);
	o.put(2);
	assert(obs.pending);
	obs.popFront();
	assert(obs.front == 2);
	assert(obs.pending);
	assert(!obs.empty);
	obs.popFront();
	assert(!obs.pending);
	o.close();
	assert(obs.empty);
}

import std.range : isInputRange;
static assert(isInputRange!(Observer!int));


/** Thrown by `Observer.consumeOne` in case there are no more events left.
*/
class ObserverClosedException : Exception {
	this(string file = __FILE__, size_t line = __LINE__)
	{
		super("Attempt to consume event from closed observer.", file, line);
	}
}


/** Applies a transformation on the events emitted by an observer.

	The return value is an observer that emits the transformed events.
*/
auto map(alias fun, O)(O source)
	if (isObservable!O)
{
	alias T = ObservableType!O;
	alias TM = typeof(fun(T.init));

	static struct OM {
		private O source;

		alias Event = ObservedEvent!TM;

		void connect(C, ARGS...)(ref SignalConnection connection, C callable, ARGS args)
		{
			source.connect(connection, function(ObservedEvent!T val, C callable, ARGS args) {
					final switch (val.kind) with (ObservedEvent!T.Kind) {
						case close: callable(ObservedEvent!TM.close(), args); break;
						case event: callable(ObservedEvent!TM.event(fun(val.eventValue)), args); break;
					}
				}, callable, args);
		}
	}

	static assert(isObservable!OM);

	return OM(source);
}

///
unittest {
	ObservableSource!int source;
	auto observer = source
		.map!(i => 2 * i)
		.subscribe();

	source.put(1);
	source.put(2);
	source.put(3);

	assert(observer.consumeOne == 2);
	assert(observer.consumeOne == 4);
	assert(observer.consumeOne == 6);
}


/** Combines multiple observers into one.

	The events of the input observables will be stored in a `TaggedUnion` and
	will be emitted by the combined observable interleaved in the same order as
	they occurred.

	The values of the tagged union can be accessed using `evt.observer0Value`,
	`evt.observer1Value` etc., or by type using `evt.value!T`, with `T` being
	the event type of one or more of the source observers.
*/
auto merge(OBSERVERS...)(OBSERVERS observers)
	if (allSatisfy!(isObservable, OBSERVERS))
{
	import std.algorithm.mutation : swap;
	import std.algorithm.searching : all;

	alias RawTypes = staticMap!(ObservableType, OBSERVERS);
	alias Types = ObserverNamedTypes!RawTypes;
	alias TM = TaggedUnion!Types;

	static struct ES {
		OBSERVERS sources;
		bool[OBSERVERS.length] closed;
		SignalConnection[OBSERVERS.length] connections;

		@disable this(this);
		this(ref return scope ES rhs) { this.tupleof = rhs.tupleof; }
	}

	static void onSourceEvent(size_t i)(ObservedEvent!(RawTypes[i]) val,
		ObservableSource!(TM, ES) target)
	nothrow {
		final switch (val.kind) with (ObservedEvent!(RawTypes[i]).Kind) {
			case close:
				scope ES* es = () @trusted { return &target.extraStorage(); } ();
				assert(es.sources[i].closed, "Observer sent close, but is not closed!?");
				assert(!target.closed, "An observer was closed after the merged observer is already closed!?");

				es.connections[i].disconnect();
				es.closed[i] = true;

				bool all_closed = true;
				static foreach (i; 0 .. OBSERVERS.length)
					if (!es.closed[i])
						all_closed = false;
				if (all_closed) target.close();
				break;
			case event:
				auto et = mixin("TM.observer"~i.stringof~"(val.eventValue)");
				target.put(et);
				break;
		}
	}

	ObservableSource!(TM, ES) ret;
	scope ES* es = () @trusted { return &ret.extraStorage(); } ();
	foreach (i, O; OBSERVERS) {
		swap(es.sources[i], observers[i]);

		if (!es.closed[i])
			es.sources[i].connect(es.connections[i], &onSourceEvent!i, ret);
	}
	return ret;
}

///
unittest {
	ObservableSource!int oint;
	ObservableSource!string ostr;

	auto observer = merge(oint, ostr)
		.subscribe();

	oint.put(1);
	ostr.put("foo");
	oint.put(2);
	oint.put(3);
	oint.close();
	ostr.put("bar");
	ostr.close();

	assert(observer.consumeOne.value!int == 1);
	assert(observer.consumeOne.value!string == "foo");
	assert(observer.consumeOne.value!int == 2);
	assert(observer.consumeOne.value!int == 3);
	assert(observer.consumeOne.value!string == "bar");
	assert(observer.empty);
}

private struct ObserverNamedTypes(TYPES...)
{
	static foreach (i, T; TYPES)
		mixin("TYPES["~i.stringof~"] observer"~i.stringof~";");
}


/** Records the time at which each event was emitted.

	Returns an observable that emits `TimestampedEvent` events with the
	`MonoTime` timestamp of the original occurrence of each event.
*/
auto timestamp(O)(ref O source)
{
	import core.time : MonoTime;
	alias T = ObservableType!O;
	return source.map!(val => TimestampedEvent!T(val, MonoTime.currTime()));
}

struct TimestampedEvent(T)
{
	import core.time : MonoTime;
	T event;
	MonoTime timestamp;
}


/** Forwards the events emitted by an observable with a fixed delay.
*/
auto delay(O)(ref O source, Duration delay)
	if (isObservable!O)
{
	import vibe.core.core : runTask, sleep;
	import core.time : MonoTime;

	alias T = ObservableType!O;

	ObservableSource!T delayed;

	runTask(function (O source, ObservableSource!T delayed, Duration delay) nothrow {
		scope (exit) delayed.close();

		foreach (val; source.timestamp.subscribe) {
			auto tt = val.timestamp + delay;
			auto tm = MonoTime.currTime();
			if (tm < tt) {
				try sleep(tt - tm);
				catch (Exception e) {
					logException(e, "Sleep in observer delay() got interrupted unexpectedly");
					break;
				}
			}
			delayed.put(val.event);
		}
	}, source, delayed, delay);

	return delayed;
}

///
unittest {
	import core.time : msecs;
	import std.algorithm.iteration : each;
	import std.datetime.stopwatch : StopWatch;
	import vibe.core.core : runTask, sleep;
	import vibe.core.log : logInfo;

	ObservableSource!int source;
	StopWatch sw;

	auto t1 = runTask({
		source
			.subscribe()
			.each!((evt) {
				logInfo("%3d ms, immediate: %s", sw.peek.total!"msecs", evt);
			});
	});

	auto t2 = runTask({
		source
			.delay(50.msecs)
			.subscribe()
			.each!((evt) {
				logInfo("%3d ms, delayed: %s", sw.peek.total!"msecs", evt);
			});
	});

	// quick and dirty wait to let the tasks subscribe
	sleep(10.msecs);

	sw.start();

	source.put(1);
	source.put(2);
	sleep(100.msecs);
	source.put(3);
	source.close();

	t1.join();
	t2.join();

	// expected output:
	//   0 ms, immediate: 1
	//   0 ms, immediate: 2
	//  50 ms, delayed: 1
	//  50 ms, delayed: 2
	// 100 ms, immediate: 3
	// 150 ms, delayed: 3
}
