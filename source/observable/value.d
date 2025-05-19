/** Implements a reactive value interface with various implementations.

	Copyright: Copyright © 2011-2022 Sönke Ludwig
	Authors: Sönke Ludwig
*/
module observable.value;

import core.time : Duration;
import observable.observable;
import observable.signal;
import std.conv;
import std.exception;
import std.meta : allSatisfy, staticMap;


/** Maps one or more reactive values using a predicate.

	The result of this operation is a read-only reactive value that gets updated
	with `pred(values)` whenever any of `values` changes.

	As an optimization, the predicate will only be invoked if either at least
	one observer is connected to the returned value, or when the value is
	explicitly read.
*/
auto mapValue(alias pred, V...)(auto ref V values)
	if (allSatisfy!(isReactiveValue, V))
{
	import std.typecons : RefCounted, RefCountedAutoInitialize, refCounted;

	alias T = staticMap!(ValueType, V);
	alias U = typeof(pred(T.init));

	static struct Context {
		alias Ref = RefCounted!(Context, RefCountedAutoInitialize.no);

		@disable this(this);
		Signal!(ObservedEvent!U) eventSignal;
		SignalConnection[V.length] conns;
		T inputValues;
		bool valuePending;
		U value;

		U getValue()
		{
			if (valuePending) {
				valuePending = false;
				value = pred(inputValues);
			}
			return value;
		}
	}

	static struct MappedValue {
		alias Event = ObservedEvent!U;

		private {
			Context.Ref m_ctx;
		}

		void connect(C, ARGS...)(ref SignalConnection conn, auto ref C callable, auto ref ARGS args)
		{
			m_ctx.eventSignal.socket.connect(conn, callable, args);
		}

		alias get this;

		@property U get() { return m_ctx.getValue(); }
	}

	static void onEvent(size_t i)(V[i].Event evt, Context.Ref ctx)
	{
		final switch (evt.kind) with (Value!(T[i]).Event.Kind) {
			case close:
				ctx.eventSignal.emit(MappedValue.Event.close);
				break;
			case event:
				ctx.inputValues[i] = evt.eventValue;
				ctx.valuePending = true;
				if (!ctx.eventSignal.empty)
					ctx.eventSignal.emit(MappedValue.Event(ctx.getValue()));
				break;
		}
	}

	MappedValue ret;
	ret.m_ctx.refCountedStore.ensureInitialized();
	ret.m_ctx.valuePending = true;

	static foreach (i; 0 .. V.length) {
		ret.m_ctx.inputValues[i] = values[i].get;
		values[i].connect(ret.m_ctx.conns[i], &onEvent!i, ret.m_ctx);
	}
	return ret;
}

///
unittest {
	import std.conv : to;

	Value!int v;
	v = 1;

	Value!string vs;
	vs = v.mapValue!(i => i.to!string);
	assert(vs == "1");
	v = 2;
	assert(vs == "2");
}

///
unittest {
	Value!int a, b, c;
	a = 1;
	b = 2;

	// bind the map result to c
	c = mapValue!((i, j) => i + j)(a, b);
	assert(c == 3);

	// any update of a or b should set a new result in c
	a = 4;
	assert(c == 6);
	b = 4;
	assert(c == 8);

	// destroying one of the input values cancels the connection
	destroy(a);
	b = 5;
	assert(c == 8);
}

static assert (isObservable!(typeof(Value!int.init.mapValue!(i => "foo"))));
static assert (isReactiveValue!(typeof(Value!int.init.mapValue!(i => "foo"))));


/** Determines whether the given type implements the reactive value interface.
*/
enum isReactiveValue(V) = isObservable!V && is(typeof(V.init.get));


/** Determines the stored type within a reactive value.
*/
template ValueType(V) if (isReactiveValue!V) {
	alias ValueType = typeof(V.init.get);
}


/** Wrapper for a value with observable semantics.

	This struct can be used to construct responsive connections between
	components, either unidirectional, by assigning one `Value` to another,
	or bidirectional using `synchronizeWith`.

	It also provides some additional monitoring functionality, such as
	intercepting newly set values and waiting for a certain condition to apply.
*/
struct Value(T)
{
	alias Event = ObservedEvent!T;

	private {
		T m_value;
		void delegate(ref T) @safe nothrow m_interceptor;
		Signal!(T) m_beforeChangeSignal;
		Signal!() m_changeSignal;
		Signal!(T) m_changeSignalV;
		Signal!() m_afterChangeSignal;
		Signal!Event m_eventSignal;
		SignalConnection m_assignConnection;
	}

	@disable this(this);

	this(T v, void delegate(ref T) @safe nothrow interceptor = null)
	{
		m_value = v;
		m_interceptor = interceptor;
	}

	~this()
	{
		m_eventSignal.emit(Event.close);
	}

	/// Assigns a new static value
	void opAssign(U : T)(U val) if (!isReactiveValue!U)
	{
		set(val);
	}

	/** Assigns/binds another `Value` dynamically.

		Any later value changes in `val` will also change the value of this
		instance accordingly.
	*/
	void opAssign(U)(auto ref U val) if (isReactiveValue!U)
	{
		set(val.get);
		val.connect(m_assignConnection, &setFromEvent);
	}

	/// Enables arithmetic assignment operations with the expected semantics.
	void opOpAssign(string op, U)(U other)
	{
		T tmp = get();
		mixin("tmp "~op~"= other;");
		this = tmp;
	}

	/// Makes `Value!T` usable in places where `T` is expected
	alias get this;

	/// Emitted after a new value has been set
	@property ref SignalSocket!() changeSignal() { return m_changeSignal.socket; }
	/// ditto
	@property ref SignalSocket!T changeVSignal() { return m_changeSignalV.socket; }
	/// Emitted just before a new value gets set
	@property ref SignalSocket!T beforeChangeSignal() { return m_beforeChangeSignal.socket; }
	/// Emitted just after a newly set value has been reported
	@property ref SignalSocket!() afterChangeSignal() { return m_afterChangeSignal.socket; }

	/** Connects an observer to this value

		This method is typically called by `subscribe()` in order to create
		an observer for this value.
	*/
	void connect(C, ARGS...)(ref SignalConnection connection, auto ref C callable, auto ref ARGS args)
		if (is(typeof(callable(Event.init, args))))
	{
		static assert(__traits(compiles, () nothrow { callable(Event.init, args); }),
			"Observable connection callback must be nothrow.");

		m_eventSignal.socket.connect(connection, callable, args);
	}


	/** Explicitly gets the current value.

		This method can be used to get the contained value in cases where an
		explicit syntax is needed.
	*/
	@property inout(T) get() inout { return m_value; }

	/** Explicitly sets a new value.

		This method can be used to set the contained value in cases where an
		explicit syntax is needed.
	*/
	void set(T val)
	{
		m_assignConnection.disconnect();
		doSet(val);
	}

	/// Returns a read-only view of this `Value`.
	ConstValue!T toConst() { return ConstValue!T(&this); }

	/** Waits on a `Value` until the specified condition is met.
	*/
	void waitUntil(scope bool delegate(T) @safe predicate)
	{
		doWaitUntil!(T, false)(this, Duration.max, predicate);
	}
	/// ditto
	bool waitUntil(Duration timeout, scope bool delegate(T) @safe predicate)
	{
		return doWaitUntil!(T, false)(this, timeout, predicate);
	}
	///
	void waitUntilUninterruptible(scope bool delegate(T) @safe nothrow predicate)
	{
		doWaitUntil!(T, true)(this, Duration.max, predicate);
	}
	/// ditto
	bool waitUntilUninterruptible(Duration timeout, scope bool delegate(T) @safe nothrow predicate)
	{
		return doWaitUntil!(T, true)(this, timeout, predicate);
	}

	private void doSet(T val)
	{
		if (m_interceptor) m_interceptor(val);
		if (m_value !is val) {
			m_beforeChangeSignal.emit(val);
			if (m_value is val) return;
			m_value = val;
			m_changeSignal.emit();
			m_changeSignalV.emit(m_value);
			m_afterChangeSignal.emit();
			m_eventSignal.emit(Event(m_value));
		}
	}

	private void setFromEvent(Event evt)
	{
		final switch (evt.kind) {
			case Event.Kind.close:
				m_assignConnection.disconnect();
				break;
			case Event.Kind.event:
				doSet(evt.eventValue);
				break;
		}
	}
}

static assert (isObservable!(Value!int));
static assert (isReactiveValue!(Value!int));


/** Read-only view of a `Value!T`.
*/
struct ConstValue(T) {
	alias Event = Value!T.Event;

	private {
		Value!T* m_value;
	}

	private this(Value!T* value)
	{
		m_value = value;
	}

	/// Makes `ConstValue!T` usable in places where `T` is expected
	alias get this;

	@property ref SignalSocket!() changeSignal() { assert(!!m_value); return m_value.changeSignal; }
	@property ref SignalSocket!T changeVSignal() { assert(!!m_value); return m_value.changeVSignal; }
	@property ref SignalSocket!T beforeChangeSignal() { assert(!!m_value); return m_value.beforeChangeSignal; }
	@property ref SignalSocket!() afterChangeSignal() { assert(!!m_value); return m_value.afterChangeSignal; }

	/** Connects an observer to this value

		This method is typically called by `subscribe()` in order to create
		an observer for this value.
	*/
	void connect(C, ARGS...)(ref SignalConnection connection, C callable, ARGS args)
		if (is(typeof(callable(Event.init, args))))
	{
		assert(!!m_value);
		m_value.connect(connection, callable, args);
	}

	/// explicit getter
	@property inout(T) get() inout { assert(!!m_value); return m_value.get; }

	/** Waits on a `Value` until the specified condition is met.
	*/
	void waitUntil(scope bool delegate(T) @safe predicate)
	{
		assert(!!m_value);
		m_value.waitUntil(predicate);
	}
	/// ditto
	bool waitUntil(Duration timeout, scope bool delegate(T) @safe predicate)
	{
		assert(!!m_value);
		return m_value.waitUntil(timeout, predicate);
	}
	///
	void waitUntilUninterruptible(scope bool delegate(T) @safe nothrow predicate)
	{
		assert(!!m_value);
		m_value.waitUntilUninterruptible(predicate);
	}
	/// ditto
	bool waitUntilUninterruptible(Duration timeout, scope bool delegate(T) @safe nothrow predicate)
	{
		assert(!!m_value);
		return m_value.waitUntilUninterruptible(timeout, predicate);
	}
}

static assert (isObservable!(ConstValue!int));
static assert (isReactiveValue!(ConstValue!int));


unittest { // test Observable support
	import observable.observable : subscribe;

	Value!int v;
	v = 1;
	auto o = v.subscribe();
	v = 2;
	v = 3;
	assert(o.consumeOne == 2);
	assert(o.consumeOne == 3);

	auto vc = v.toConst;
	assert(vc == 3);
	auto oc = vc.subscribe();
	v = 4;
	v = 5;
	assert(oc.consumeOne == 4);
	assert(!oc.empty);
	assert(oc.consumeOne == 5);

	destroy(v);
	assert(oc.empty);
	assert(o.consumeOne == 4);
	assert(o.consumeOne == 5);
	assert(o.empty);
}

unittest { // test bound assignment
	Value!int a, b;
	a = 12; assert(a == 12);
	// bind b to a
	b = a; assert(b == 12);
	// b should follow a
	a = 13; assert(a == 13); assert(b == 13);
	// unbind b by setting to a different value
	b = 14; assert(a == 13); assert(b == 14);
	// should be unbound now
	a = 15; assert(a == 15); assert(b == 14);
}


/** Keeps two values bi-directionally synchronized.

	Initially, `target` will be set to the value of `src`, before the
	bi-directional synchronization is established.

	To stop the synchronization at a later point, the `conns` connection can be
	cleared.
*/
void synchronizeWith(T, U)(ref Value!T src, ref Value!U target, ref SignalConnectionContainer conns)
	if (is(T : U) && is(U : T))
{
	// FIXME: We are capturing the references to the Value!T instances in
	//        closures here. Since D so far does not support disabling implicit
	//        moves of struct instances, this could lead to memory corruption
	//        issues under certain circumstances. To work around this, we'd have
	//        to perform some kind of dynamic memory allocation (could use
	//        reference counting). Unfortunately that would have to happen
	//        within Value!T and cannot be done here, which would be highly
	//        undesirable.
	target.set(src.get());
	bool updating_source;
	target.beforeChangeSignal.connect(conns, (v) {
		updating_source = true;
		scope (exit) updating_source = false;
		src.set(v);
	});
	target.afterChangeSignal.connect(conns, {
		target = src.get;
	});
	src.changeVSignal.connect(conns, (v) {
		if (!updating_source)
			target.set(v);
	});
}

///
nothrow unittest {
	// initialize two different values
	Value!int a, b;
	a = 10;
	b = 20;

	// synchronize both values
	SignalConnectionContainer conns;
	a.synchronizeWith(b, conns);
	assert(a == 10);
	assert(b == 10);
	a = 11;
	assert(a == 11);
	assert(b == 11);
	b = 12;
	assert(a == 12);
	assert(b == 12);

	// break the connection
	conns.clear();
	a = 13;
	assert(a == 13);
	assert(b == 12);
	b = 14;
	assert(a == 13);
	assert(b == 14);
}

/** Similar to `synchronizeWith`, synchronizes a `Value` with another value.

	In contrast to `syncrhronizeWith`, this works using a bare `Signal`,
	combined with getters and setters.
*/
void synchronizeWithSignal(T, GETTER, SETTER)(ref Value!T src,
	ref SignalSocket!T target_change, SETTER target_setter,
	ref SignalConnectionContainer conns)
{
	target_setter(src.get());
	bool updating_source;
	target_change.connect(conns, (T value) nothrow {
		if (updating_source) return;
		updating_source = true;
		scope (exit) updating_source = false;
		src.set(value);
	});
	src.changeVSignal.connect(conns, (T v) nothrow {
		if (!updating_source)
			target_setter(v);
	});
}
/// ditto
void synchronizeWithSignal(T, GETTER, SETTER)(ref Value!T src,
	ref SignalSocket!() target_change, GETTER target_getter,
	SETTER target_setter, ref SignalConnectionContainer conns)
{
	target_setter(src.get());
	bool updating_source;
	target_change.connect(conns, () nothrow {
		if (updating_source) return;
		updating_source = true;
		scope (exit) updating_source = false;
		src.set(target_getter());
	});
	src.changeVSignal.connect(conns, (T v) nothrow {
		if (!updating_source)
			target_setter(v);
	});
}


private bool doWaitUntil(T, bool uninterruptible, P)(ref Value!T value, Duration timeout, scope P predicate)
{
	import core.time : MonoTime, seconds;
	import vibe.core.sync : createManualEvent;

	if (predicate(value.get)) return true;

	auto et = MonoTime.currTime() + timeout;

	auto evt = createManualEvent();
	int cnt = evt.emitCount;
	SignalConnection conn;
	// NOTE: evt is guaranteed to be disconnected before its EOL, due to the
	//       scoped conn
	value.changeSignal.connect(conn, () @trusted { return &evt.emit; } ());
	while (true) {
		if (timeout != Duration.max) {
			auto to = et - MonoTime.currTime;
			if (to < 0.seconds) return false;
			static if (uninterruptible) cnt = evt.waitUninterruptible(to, cnt);
			else cnt = evt.wait(to, cnt);
		} else {
			static if (uninterruptible) cnt = evt.waitUninterruptible(cnt);
			else cnt = evt.wait(cnt);
		}
		if (predicate(value.get)) return true;
	}
}

@safe unittest {
	import vibe.core.core : runTask, sleepUninterruptible;
	import core.time : MonoTime, msecs, seconds;

	Value!int value;
	runTask(() @safe {
		sleepUninterruptible(50.msecs);
		value = 2;
	});
	value.waitUntil(v => v == 2);
	assert(value == 2);

	runTask(() @safe {
		sleepUninterruptible(50.msecs);
		value = 3;
	});
	assert(value.waitUntil(1.seconds, (int v) => v == 3));
	assert(value == 3);

	auto tm = MonoTime.currTime;
	assert(!value.waitUntil(50.msecs, (int v) => v == 4));
	assert(MonoTime.currTime - tm >= 50.msecs);
}

@safe nothrow unittest {
	import vibe.core.core : runTask, sleepUninterruptible;
	import core.time : MonoTime, msecs, seconds;

	Value!int value;
	runTask({
		sleepUninterruptible(50.msecs);
		value = 2;
	});
	value.waitUntilUninterruptible((int v) => v == 2);
	assert(value == 2);

	runTask({
		sleepUninterruptible(50.msecs);
		value = 3;
	});
	assert(value.waitUntilUninterruptible(1.seconds, (int v) => v == 3));
	assert(value == 3);

	auto tm = MonoTime.currTime;
	assert(!value.waitUntilUninterruptible(50.msecs, (int v) => v == 4));
	assert(MonoTime.currTime - tm >= 50.msecs);
}
