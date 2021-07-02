/**
	Signals/slots implementation.

	See `Signal` for usage examples.

	Copyright: Copyright © 2007-2021 Sönke Ludwig
	Authors: Sönke Ludwig
*/
module observable.signal;

import core.sync.mutex;
import core.thread;
import std.algorithm;
import std.traits : isInstanceOf;
import vibe.core.core;
import vibe.core.concurrency;


/** A thread local signal-slot implementation.
*/
struct Signal(P...) {
	alias Params = P;
	alias Slot = void delegate(P) nothrow;

	private {
		SignalSocket!Params m_socket;
	}

	@disable this(this);
	this(ref return scope Signal rhs)
	{
		m_socket = rhs.m_socket;
	}

	/// Determines if any connections are connected to the signal.
	@property bool empty() const { return m_socket.empty; }

	/// Returns a reference to the socket of this signal.
	@property ref SignalSocket!Params socket() { return m_socket; }

	/// Detaches all connections from the signal.
	void disconnectAll() { m_socket.disconnectAll(); }

	/** Emits the signal.

		This will iterate through all connections in the order in which they
		were registered and calls the associated slot with the given parameters.

		Note that it is legal to disconnect any single connection of the signal
		from within a callback, as well as calling `disconnectAll`. However,
		disconnecting multiple connections from a callback may result in some
		outstanding callbacks to get skipped.
	*/
	void emit(P params) nothrow { m_socket.emit(params); }
}

///
@safe nothrow unittest {
	// declare a signal
	Signal!int signal;

	{
		// define a connection
		SignalConnection conn;

		// establish a connection between the signal and a delegate
		signal.socket.connect(conn, (i) { assert(i == 42); });

		// emitting the signal will call the above delegate
		signal.emit(42);
	}

	// once there are no copies of the connection left, it will
	// automatically disconnect, so the following emit will
	// not have an effect.
	signal.emit(13);


	// if a class connects to a member function, it must store the connection,
	// so that the connection life time is limited to the instance lifetime.
	class Test {
		SignalConnection conn;

		this()
		@safe nothrow {
			signal.socket.connect(conn, &slot);
		}

		void slot(int i)
		@safe nothrow {
			assert(i == 32);
		}
	}

	auto t = new Test;
	signal.emit(32);
}

/// This example shots the recommended convention for defining signals.
unittest {
	class Widget {
		private {
			Signal!bool m_visibilityChangeSignal;
		}

		@property ref SignalSocket!bool visibilityChangeSignal() { return m_visibilityChangeSignal.socket; }

		void setVisibility(bool v)
		{
			// ...
			m_visibilityChangeSignal.emit(v);
		}
	}

	class Layout {
		private {
			SignalConnection m_visConn;
			Widget m_client;
		}

		void setClient(Widget w)
		{
			m_client = w;
			// automatically disconnects a possible connection to a previous widget
			w.visibilityChangeSignal.connect(m_visConn, &onChildVisibilityChange);
		}

		void onChildVisibilityChange(bool)
		nothrow {
			// ...
		}
	}

	auto l = new Layout;
	auto w = new Widget;
	l.setClient(w);
	w.setVisibility(true);
}

// connecting @system callbacks and using @system parameters should be @system
unittest {
	Signal!int sig;
	struct C { void opCall(int) @safe nothrow {} }
	struct CS { void opCall(int) @system nothrow {} }
	struct US { this(this) @system nothrow {} }

	SignalConnection c;
	static assert(__traits(compiles, () @safe { sig.socket.connect(c, (i) @safe {}); }));
	static assert(!__traits(compiles, () @safe { sig.socket.connect(c, (i) @system {}); }));
	static assert(__traits(compiles, () @safe { C clbl; sig.socket.connect(c, clbl); }));
	static assert(!__traits(compiles, () @safe { CS clbl; sig.socket.connect(c, clbl); }));
	() @safe { sig.emit(0); } ();

	Signal!US usig;
	static assert(__traits(compiles, () @system { usig.socket.connect(c, (i) @safe {}); }));
	static assert(!__traits(compiles, () @safe { usig.socket.connect(c, (i) @safe {}); }));
	static assert(__traits(compiles, (ref US p) @system { usig.emit(p); }));
	static assert(!__traits(compiles, (ref US p) @safe { usig.emit(p); }));
}

// test disconnectAll from within a callback
nothrow unittest {
	Signal!() sig;
	bool visited = false;
	void foo() { sig.disconnectAll(); visited = true; }
	void bar() { assert(false); }
	SignalConnectionContainer c;
	sig.socket.connect(c, &foo);
	sig.socket.connect(c, &bar);
	sig.emit();
	assert(visited);
}

// test disconnecting the current connection from within a callback
unittest {
	Signal!() sig;
	SignalConnection fconn, bconn;
	int visited = 0;
	void foo() { fconn.disconnect(); visited++; }
	void bar() { visited++; }
	sig.socket.connect(fconn, &foo);
	sig.socket.connect(bconn, &bar);
	sig.emit();
	assert(visited == 2);
}

// test fixed parameters
unittest {
	Signal!(int) sig;
	SignalConnection conn;
	bool emitted = false;
	void foo(int i, string s) { assert(i == 42 && s == "foo"); emitted = true; }
	sig.socket.connect(conn, &foo, "foo");
	sig.emit(42);
	assert(emitted);
	emitted = false;
	conn.disconnect();
	sig.emit(13);
	assert(!emitted);
}

// test copyability
unittest {
	Signal!int orig;
	Signal!int copy = orig;

	assert(orig.m_socket.m_pivot !is null);
	assert(copy.m_socket.m_pivot !is null);
	assert(orig.m_socket.m_pivot is copy.m_socket.m_pivot);

	bool got_it = false;

	SignalConnection c;
	orig.socket.connect(c, (i) {
		assert(i == 42);
		got_it = true;
	});

	copy.emit(42);

	assert(got_it);
}


/** Represents a single connection between a signal and a slot.

	This type is reference counted. When the reference count drops to zero,
	the connection will be detached automatically.
*/
struct SignalConnection {
	private ConnectionHead m_ctx;

	private this(ConnectionHead h) @safe nothrow { m_ctx = h; retain(); }

	this(this) @safe nothrow { retain(); }

	~this() @safe nothrow { release(); }

	@property bool connected() const @safe nothrow { return m_ctx !is null && m_ctx.prev !is null; }

	void disconnect()
	@safe nothrow {
		if (!m_ctx) return;
		assert(m_ctx.rc > 0, "Stale connection reference");

		if (this.connected) {
			// remove from queue
			m_ctx.prev.next = m_ctx.next;
			m_ctx.next.prev = m_ctx.prev;
			m_ctx.prev = null;
			m_ctx.next = null;
		}

		if (--m_ctx.rc == 0) // free context
			m_ctx.dispose();

		m_ctx = null;
	}

	private CallableConnectionHead!(Socket, Callable, FixedArgs) setCallable(Socket, Callable, FixedArgs...)(ref Callable callable, ref FixedArgs fixed_args)
	{
		release();

		auto cch = CallableConnectionHead!(Socket, Callable, FixedArgs).make(callable, fixed_args);
		m_ctx = cch;
		return cch;
	}

	private void retain()
	@safe nothrow {
		if (m_ctx) m_ctx.rc++;
	}

	private void release()
	@safe nothrow {
		if (m_ctx) {
			assert(m_ctx.rc > 0, "Stale connection reference");
			if (m_ctx.rc == 1) {
				disconnect();
				assert(!m_ctx);
			} else {
				--m_ctx.rc;
				m_ctx = null;
			}
		}
	}
}

///
unittest {
	Signal!() sig;
	SignalConnection conn;
	size_t cnt = 0;

	void slot() { cnt++; }

	// disconnecting using a disconnect() call
	sig.socket.connect(conn, &slot);
	sig.emit();
	assert(cnt == 1);
	conn.disconnect();
	assert(!conn.connected);
	sig.emit();
	assert(cnt == 1);

	// disconnecting by destroying/overwriting the connection object
	sig.socket.connect(conn, &slot);
	sig.emit();
	assert(cnt == 2);
	conn = SignalConnection.init;
	assert(!conn.connected);
	sig.emit();
	assert(cnt == 2);

	// disconnecting through the signal
	sig.socket.connect(conn, &slot);
	sig.emit();
	assert(cnt == 3);
	sig.disconnectAll();
	assert(!conn.connected);
	sig.emit();
	assert(cnt == 3);

	// disconnecting by destroying the signal
	sig.socket.connect(conn, &slot);
	sig.emit();
	assert(cnt == 4);
	destroy(sig);
	assert(!conn.connected);
	sig.emit();
	assert(cnt == 4);
}

unittest {
	Signal!() sig;
	SignalConnection conn, conn2;
	size_t cnt = 0;

	void slot() { cnt++; }

	sig.socket.connect(conn, &slot);
	assert(conn.connected && !conn2.connected);
	sig.emit();
	assert(cnt == 1);
	conn2 = conn;
	assert(conn.connected && conn2.connected);
	sig.emit();
	assert(cnt == 2);
	conn.disconnect();
	assert(!conn.connected && !conn2.connected);
	sig.emit();
	assert(cnt == 2);
}

unittest {
	Signal!() sig;
	SignalConnection conn, conn2;
	size_t cnt = 0;

	void slot() { cnt++; }

	sig.socket.connect(conn, &slot);
	assert(conn.connected && !conn2.connected);
	sig.emit();
	assert(cnt == 1);
	conn2 = conn;
	assert(conn.connected && conn2.connected);
	sig.emit();
	assert(cnt == 2);
	destroy(conn);
	assert(!conn.connected && conn2.connected);
	sig.emit();
	assert(cnt == 3);
	destroy(conn2);
	assert(!conn.connected && !conn2.connected);
	sig.emit();
	assert(cnt == 3);
}

/** A container for multiple connections that share the same life time.
*/
struct SignalConnectionContainer {
	import std.container.array : Array;

	private {
		SignalConnection[4] m_smallConnections;
		size_t m_smallConnectionCount;
		//Array!SignalConnection m_connections;
		SignalConnection[] m_connections;
	}

	this(this)
	@safe nothrow {
		if (m_connections.length) m_connections = m_connections.dup;
	}

	~this()
	@safe nothrow {
		clear();
	}

	void add(SignalConnection conn)
	@safe nothrow {
		if (m_smallConnectionCount < m_smallConnections.length)
			m_smallConnections[m_smallConnectionCount++] = conn;
		else {
			auto oldconn = m_connections;
			m_connections ~= conn;
			// don't leave stale connections behind after reallocations
			if (oldconn.ptr !is m_connections.ptr)
				oldconn[] = SignalConnection.init;
		}
	}

	void clear()
	@safe nothrow {
		m_connections[] = SignalConnection.init;
		m_connections.length = 0;
		() @trusted { m_connections.assumeSafeAppend(); } ();
		//m_connections.clear();
		m_smallConnections[0 .. m_smallConnectionCount] = SignalConnection.init;
		m_smallConnectionCount = 0;
	}
}

unittest {
	SignalConnectionContainer c;
	Signal!() sig;
	size_t cnt = 0;
	foreach (i; 0 .. 10) sig.socket.connect(c, { cnt++; });
	assert(cnt == 0);
	sig.emit();
	assert(cnt == 10);
	c.clear();
	sig.emit();
	assert(cnt == 10);
}

unittest {
	SignalConnectionContainer c;
	Signal!() sig;
	size_t cnt = 0;
	foreach (i; 0 .. 10) sig.socket.connect(c, { cnt++; });
	assert(cnt == 0);
	sig.emit();
	assert(cnt == 10);
	c = SignalConnectionContainer.init;
	sig.emit();
	assert(cnt == 10);
}


/** Signal side endpoint used to connect to slots.
*/
static struct SignalSocket(PARAMS...) {
	alias Params = PARAMS;

	// NOTE: the int fixed parameter of Pivot is used to store the reference
	//       count for enabling copyability of SignalSocket
	private static struct DummyCalllable { void opCall(Params, int) { assert(false, "Signal pivot invoked!?"); } }
	private alias Pivot = CallableConnectionHead!(SignalSocket, DummyCalllable, int);

	private {
		Pivot m_pivot;
	}

	@disable this(this);
	this(ref return scope SignalSocket rhs)
	{
		if (!rhs.m_pivot) rhs.initializePivot();

		m_pivot = rhs.m_pivot;
		m_pivot.fixedParams[0]++;
	}

	~this()
	{
		if (m_pivot) {
			if (!--m_pivot.fixedParams[0]) {
				disconnectAll();
				assert(m_pivot.next is m_pivot && m_pivot.prev is m_pivot);
				m_pivot.dispose();
			}
		}
	}

	void connect(ref SignalConnection c, void delegate(Params) @system nothrow callable)
	{
		push(c.setCallable!SignalSocket(callable));
	}

	void connect(ref SignalConnectionContainer cc, void delegate(Params) @system nothrow callable)
	{
		SignalConnection c;
		connect(c, callable);
		cc.add(c);
	}

	void connect(ref SignalConnection c, void delegate(Params) @safe nothrow callable)
	{
		push(c.setCallable!SignalSocket(callable));
	}

	void connect(ref SignalConnectionContainer cc, void delegate(Params) @safe nothrow callable)
	{
		SignalConnection c;
		connect(c, callable);
		cc.add(c);
	}

	void connect(Callable, FixedParams...)(ref SignalConnection c, Callable callable, FixedParams fixed_args)
		if (
			!is(Callable : void delegate(Params))
			&& is(typeof(Callable.init(Params.init, FixedParams.init)))
			&& __traits(compiles, () nothrow { Callable.init(Params.init, FixedParams.init); })
		)
	{
		push(c.setCallable!SignalSocket(callable, fixed_args));
	}

	void connect(Callable, FixedParams...)(ref SignalConnectionContainer cc, Callable callable, FixedParams fixed_args)
		if (
			!is(Callable : void delegate(Params))
			&& is(typeof(Callable.init(Params.init, FixedParams.init)))
			&& __traits(compiles, () nothrow { Callable.init(Params.init, FixedParams.init); })
		)
	{
		SignalConnection c;
		connect(c, callable, fixed_args);
		cc.add(c);
	}

	deprecated("Use a nothrow callable.")
	{
		void connect(ref SignalConnection c, void delegate(Params) callable)
		{
			connect(c, &nothrowWrap!(typeof(callable)), callable);
		}

		void connect(ref SignalConnectionContainer cc, void delegate(Params) callable)
		{
			connect(cc, &nothrowWrap!(typeof(callable)), callable);
		}

		void connect(Callable, FixedParams...)(ref SignalConnection c, Callable callable, FixedParams fixed_args)
			if (
				!is(Callable : void delegate(Params))
				&& is(typeof(Callable.init(Params.init, FixedParams.init)))
				&& !__traits(compiles, () nothrow { Callable.init(Params.init, FixedParams.init); })
			)
		{
			connect(c, &nothrowWrap!(Callable, FixedParams), callable, fixed_args);
		}

		void connect(Callable, FixedParams...)(ref SignalConnectionContainer cc, Callable callable, FixedParams fixed_args)
			if (
				!is(Callable : void delegate(Params))
				&& is(typeof(Callable.init(Params.init, FixedParams.init)))
				&& !__traits(compiles, () nothrow { Callable.init(Params.init, FixedParams.init); })
			)
		{
			connect(cc, &nothrowWrap!(Callable, FixedParams), callable, fixed_args);
		}

		private static void nothrowWrap(C, FP...)(Params args0, C callable, FP args1)
		{
			try callable(args0, args1);
			catch (Exception e) {
				import vibe.core.log : logDebug, logError;
				logError("Signal callback has thrown - ignoring: %s", e.msg);
				logDebug("Full error: %s", e.toString());
			}
		}
	}

	private @property bool empty() const { return !m_pivot || m_pivot.next is m_pivot; }

	private void push(TypedConnectionHead!Params ctx)
	{
		if (!m_pivot) initializePivot();

		// enqueue as the last element
		ctx.prev = m_pivot.prev;
		ctx.next = m_pivot;
		m_pivot.prev.next = ctx;
		m_pivot.prev = ctx;
	}

	private void disconnectAll()
	{
		if (!m_pivot) return;

		while (m_pivot.next !is m_pivot)
			SignalConnection(m_pivot.next).disconnect();

		assert(!m_pivot || (m_pivot.next is m_pivot && m_pivot.prev is m_pivot));
	}

	private void initializePivot()
	{
		assert(!m_pivot);

		DummyCalllable nf;
		int refcount = 1;
		m_pivot = Pivot.make(nf, refcount);
		m_pivot.prev = m_pivot.next = m_pivot;
	}

	private void emit(ref Params params)
	nothrow {
		if (!m_pivot || m_pivot is m_pivot.next) return;

		// make emit @system in case Params cannot be copied/destroyed @safely
		static if (!__traits(compiles, () @safe { Params p; auto q = p; }))
			systemFun();

		// NOTE using SignalConnection to ensure that the ConnectionHeads don't
		// get destroyed while iterating over the list
		auto el = SignalConnection(m_pivot.next);
		do {
			SignalConnection elnext;
			if (el.m_ctx.next !is m_pivot)
				elnext = SignalConnection(el.m_ctx.next);

			(cast(TypedConnectionHead!Params)el.m_ctx).call(params);

			// go to the next best element if possible
			if (el.m_ctx.next is m_pivot) break;
			if (el.connected) el = SignalConnection(el.m_ctx.next);
			else el = elnext;
		} while (el.connected);
	}
}

private class ConnectionHead {
	ConnectionHead prev, next;
	int rc = 1;

	abstract void dispose() @safe nothrow;
}

private class TypedConnectionHead(P...) : ConnectionHead {
	abstract void call(ref P params) @safe nothrow;
}

private final class CallableConnectionHead(S, C, FP...) : TypedConnectionHead!(S.Params) {
	import vibe.internal.allocator : Mallocator, make, dispose;
	import std.traits : hasIndirections;
	import core.memory : GC;

	private static struct Payload { C callable; FP fixedParams; }

	C callable;
	FP fixedParams;

	this(ref C c, ref FP fp)
	{
		static if (is(typeof(move(c))))
			this.callable = move(c);
		else this.callable = c;

		static foreach (i; 0 .. FP.length) {
			static if (is(typeof(move(fp[i]))))
				this.fixedParams[i] = move(fp[i]);
			else this.fixedParams[i] = fp[i];
		}
	}

	override void call(ref S.Params params)
	@trusted {
		callable(params, fixedParams);
	}

	static CallableConnectionHead make(ref C c, ref FP fp)
	{
		// force this to be @system in case c() is @system, because the emit()
		// API is always @safe
		static if (!__traits(compiles, () @safe { S.Params p1; FP p2;  c(p1, p2); })) {
			systemFun();
		}

		// NOTE: using the GC is mandatory, so that when a class stores the
		// connection to its own member function, it isn't kept alive
		// indefinitely due to the manually allocated GC range that keeps a
		// reference
		auto ret = new CallableConnectionHead(c, fp);
		assert(ret.rc == 1);
		return ret;
	}

	final override void dispose()
	@trusted nothrow {
		destroy(callable);
		foreach (i, P; FP)
			destroy(fixedParams[i]);
		prev = next = null;
	}
}


/** A cross-thread signal struct with multiple endpoint dispatch.

	Multiple slots can be connected using connect. Each of the
	connected slots will be called when emit is called with the arguments passed
	to each slot. The order of slot invocation is undefined.

	Slots will always be called asynchronously in the same thread in which they
	were registered. Thus, SharedSignal is thread-safe, even if non-thread-safe
	delegates are used as slots. However, the argument types passed to emit()
	must be weakly shared.

	Examples:
		---
		shared(SharedSignal!int) signal;

		void setup()
		{
			auto mainthr = Thread.getThis();

			signal = new shared(SharedSignal!int);
			signal.connect((value){
				assert(Thread.getThis() is mainthr);
				writefln("Value: %d", value);
			}

			auto thr = new Thread({ signal.emit(42); });
			thr.run();
		}
		---

	See_Also: vibe.core.concurrency.isWeaklyIsolated
*/
class SharedSignal(P...) {
	///
	public alias shared(void delegate(P)) Slot;

	private static struct ThreadSlots {
		Thread thread;
		Task task;
		Slot[] slots;
	}

	private {
		Mutex m_mutex;
		ThreadSlots[] m_threads;
	}

	this()
	{
		m_mutex = new Mutex;
	}

	///
	SignalConnection connect(Slot slot)
	shared {
		auto thr = Thread.getThis();
		synchronized (m_mutex) return (cast()this).connectSync(thr, slot);
	}

	///
	void disconnect(Slot slot)
	shared nothrow {
		auto thr = Thread.getThis();
		try synchronized (m_mutex) (cast()this).disconnectSync(thr, slot);
		catch (Exception e) assert(false, e.msg);
	}

	///
	bool isSlotConnected(Slot slot)
	shared {
		auto thr = Thread.getThis();
		synchronized (m_mutex) return (cast()this).isSlotConnectedSync(thr, slot);
	}

	void emit(P params)
	shared {
		Task[16] taskbuf;
		Task[] tasks;
		synchronized (m_mutex) tasks = (cast()this).collectTasksSync(taskbuf);

		foreach (t; tasks)
			send(t, params);
	}

	private SignalConnection connectSync(Thread thr, Slot slot)
	{
		//auto ret = SignalConnection({ (cast(shared)this).disconnect(slot); });
		SignalConnection ret; // FIXME: provide a functional connection!

		foreach (ref ts; m_threads)
			if (ts.thread is thr) {
				assert(!ts.slots.canFind(slot), "Double-connecting slot.");
				auto idx = ts.slots.countUntil(cast(Slot)null);
				if (idx >= 0) ts.slots[idx] = slot;
				else ts.slots ~= slot;
				return ret;
			}

		ThreadSlots ts;
		ts.thread = thr;
		ts.task = runTask(&emitterTask);
		ts.slots = [slot];
		m_threads ~= ts;

		return ret;
	}

	private void disconnectSync(Thread thr, Slot slot)
	{
		foreach (ref ts; m_threads)
			if (ts.thread is thr) {
				auto idx = ts.slots.countUntil(slot);
				assert(idx >= 0, "Removing unconnected slot.");
				ts.slots[idx] = null;
			}
	}

	private bool isSlotConnectedSync(Thread thr, Slot slot)
	{
		foreach (ref ts; m_threads)
			if (ts.thread is thr)
				return ts.slots.canFind(slot);
		return false;
	}

	private Task[] collectTasksSync(Task[] buffer)
	{
		if (m_threads.length <= buffer.length) {
			foreach (i, ref ts; m_threads)
				buffer[i] = ts.task;
			return buffer[0 .. m_threads.length];
		}

		auto tasks = new Task[m_threads.length];
		foreach (i, ref ts; m_threads)
			tasks[i] = ts.task;
		return tasks;
	}

	private void emitterTask()
	{
		auto thr = Thread.getThis();

		while(true) {
			receive((P params){
				Slot[] slots;
				synchronized (m_mutex) {
					foreach (ref ts; m_threads)
						if (ts.thread is thr) {
							slots = ts.slots;
							break;
						}
				}
				foreach (s; slots)
					if (s) s(params);
			});
		}
	}
}


private void systemFun() @system nothrow {}
