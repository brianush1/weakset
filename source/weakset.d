module weakset;
import core.memory : GC;
import core.bitop : bsr;

private {
	__gshared Object tombstone = new Object();
	enum LOAD_FACTOR = 0.75;

	struct Bucket {
		Object obj;
		DisposeEvent evt;
	}

	// this stuff is undocumented, but it's used in std.signals
	alias DisposeEvent = void delegate(Object);
	extern (C) void rt_attachDisposeEvent(Object obj, DisposeEvent evt);
	extern (C) void rt_detachDisposeEvent(Object obj, DisposeEvent evt);
}

/++

Stores a set of items, while still allowing items to be collected by the GC.

Once an item is collected by the GC, the set will automatically update its length and the item will be removed from the set.

$(B Usage of the set should be wrapped in calls to $(REF WeakSet.lock) and $(REF WeakSet.unlock)) to ensure that the contents
of the set don't unexpectedly change while the set is being used. $(I Note that $(D foreach) loops over the set automatically
lock the set for the duration of the loop.)

Limitations:

* The current implementation assumes $(D opEquals) is not overridden, and the behavior of $(D toHash) is consistent with
hashing the pointer to the object.
* $(D null) cannot be added to the set.

Example:

----
// Creating a weak set:
WeakSet!Foo set = new WeakSet!Foo();

// Checking set membership:
bool isInTheSet = foo in set;

// Adding to/removing from the set:
set.add(foo);
set.remove(bar);

// Getting the number of items in the set:
writeln(set.length);

// Looping over the set:
foreach (item; set) {
	writeln(item, " is in the set!");
}

// Complex "transactional" operations:
{
	// set.lock() guarantees that the contents of the set will
	// not change until the set is unlocked; in other words,
	// the GC will track the contents of the set until the set
	// is unlocked
	set.lock();
	scope (exit) set.unlock();

	size_t len = set.length;
	doStuff();
	foreach (item; set) {
		writeln(item, " is part of a set with length ", len);
	}
}
----

+/
class WeakSet(T) if (is(T == class)) {

	private {
		Bucket* data;
		size_t m_length, numFilled, m_capacity;
	}

	this() {
		capacity = 16;
	}

	/++ Returns the number of items that are currently in the set. +/
	size_t length() const @property {
		// this lock is necessary because the GC might be invoked from a separate thread,
		// in which case the length may unexpectedly change while we're reading it...
		// or maybe it's not strictly necessary, but better safe than sorry
		(cast() this).lock();
		scope (exit) { (cast() this).unlock(); }

		return m_length;
	}

	/++ Returns the current capacity of the set. Guaranteed to be a positive power of 2, or 0. +/
	size_t capacity() const @property {
		(cast() this).lock(); // see .length comment
		scope (exit) { (cast() this).unlock(); }

		return m_capacity;
	}

	private void capacity(size_t value) @property {
		GC.addRange(data, m_capacity * Bucket.sizeof, typeid(Bucket));

		// save the old data and capacity so we can go through all the elements and add them back
		Bucket* oldData = data;
		size_t oldCapacity = capacity;

		// reallocate an entirely new block of data
		m_capacity = value;
		data = cast(Bucket*) GC.calloc(capacity * Bucket.sizeof, GC.BlkAttr.NO_SCAN | GC.BlkAttr.NO_INTERIOR);

		GC.addRange(data, m_capacity * Bucket.sizeof, typeid(Bucket));

		// add all the old elements back in (if there were any)
		if (oldCapacity == 0)
			return;

		m_length = 0;
		numFilled = 0;
		for (size_t i = 0; i < oldCapacity; ++i) {
			Bucket bucket = oldData[i];
			if (bucket.obj !is null && bucket.obj !is tombstone)
				addImpl(bucket.obj, bucket.evt);
		}

		GC.removeRange(data);
		GC.removeRange(oldData);
	}

	private void ensureCapacity(size_t value) {
		// we never shrink
		if (value < capacity)
			return;

		// first the first power of 2 that's >= value
		size_t newValue = 1 << bsr(value);
		if (newValue != value)
			newValue <<= 1;
		value = newValue;

		capacity = value;
	}

	private size_t probe(Object obj, bool stopAtTombstone) {
		size_t index = hashOf(obj) & (capacity - 1);
		for (size_t i = 0; i < m_capacity; ++i) {
			Bucket curr = data[index];
			if (curr.obj is obj || curr.obj is null || (stopAtTombstone && curr.obj is tombstone))
				return index;
			else
				index = (index + 1) & (capacity - 1);
		}
		return -1;
	}

	private void addImpl(Object obj, DisposeEvent handler) {
		assert(obj !is null);

		if ((numFilled + 1) > capacity * LOAD_FACTOR)
			ensureCapacity(capacity * 2);

		size_t index = probe(obj, true);
		if (data[index].obj !is obj) {
			if (data[index].obj is null)
				numFilled += 1;
			m_length += 1;

			if (handler is null) {
				handler = delegate(Object o) {
					removeImpl(o);
					GC.removeRoot(handler.ptr);
				};

				data[index] = Bucket(obj, handler);

				GC.addRoot(handler.ptr);
				rt_attachDisposeEvent(obj, handler);
			}
			else {
				data[index] = Bucket(obj, handler);
			}
		}
	}

	private bool removeImpl(Object obj) {
		if (obj is null)
			return false;

		size_t index = probe(obj, false);
		if (index == -1 || data[index].obj is null)
			return false;

		DisposeEvent evt = data[index].evt;
		GC.removeRoot(evt.ptr);
		rt_detachDisposeEvent(data[index].obj, evt);

		data[index].obj = tombstone;
		m_length -= 1;
		return true;
	}

	void add(T obj) {
		lock();
		scope (exit) { unlock(); }

		addImpl(obj, null);
	}

	bool remove(T obj) {
		lock();
		scope (exit) { unlock(); }

		return removeImpl(obj);
	}

	bool opBinaryRight(string op)(T obj) if (op == "in") {
		if (obj is null)
			return false;

		lock();
		scope (exit) { unlock(); }

		size_t index = probe(obj, false);
		return !(index == -1 || data[index].obj is null);
	}

	private int lockCount;

	void lock() {
		if (lockCount == 0)
			GC.addRange(data, m_capacity * Bucket.sizeof, typeid(Bucket));
		lockCount += 1;
	}

	void unlock() {
		lockCount -= 1;
		if (lockCount == 0)
			GC.removeRange(data);
	}

	int opApply(scope int delegate(T) dg) {
		lock();
		scope (exit) { unlock(); }

		int result = 0;

		for (size_t i = 0; i < capacity; ++i) {
			Bucket bucket = data[i];
			if (bucket.obj !is null && bucket.obj !is tombstone)
				result = dg(cast(T) bucket.obj);
			if (result)
				break;
		}

		return result;
	}

}

/++ Test that our method of measuring GC collection works +/
unittest {
	import std.random : uniform;

	GC.disable();

	int fooCount;

	class Foo {
		this() { fooCount += 1; }
		~this() { fooCount -= 1; }
	}

	size_t desiredCount = uniform!"[]"(100, 300);

	void fn() {
		foreach (i; 0 .. desiredCount) {
			new Foo();
		}

		// destroy any leftovers on the stack
		ubyte[1024] _;
	}

	fn();
	assert(fooCount == desiredCount);
	GC.collect();
	assert(fooCount == 0);
}

/++ Test that objects in a $(REF WeakSet) are collected +/
unittest {
	import std.random : uniform;

	GC.disable();

	int fooCount;

	class Foo {
		this() { fooCount += 1; }
		~this() { fooCount -= 1; }
	}

	size_t desiredCount = uniform!"[]"(100, 300);

	WeakSet!Foo set = new WeakSet!Foo();

	void fn() {
		foreach (i; 0 .. desiredCount) {
			set.add(new Foo());
		}

		// destroy any leftovers on the stack
		ubyte[1024] _;
	}

	fn();
	assert(fooCount == desiredCount);
	assert(set.length == fooCount);
	GC.collect();
	assert(fooCount == 0);
	assert(set.length == fooCount);
}

/++ Test that objects in a $(REF WeakSet) are not collected while locked, and are collected when unlocked +/
unittest {
	import std.random : uniform;

	GC.disable();

	int fooCount;

	class Foo {
		this() { fooCount += 1; }
		~this() { fooCount -= 1; }
	}

	size_t desiredCount = uniform!"[]"(100, 300);

	WeakSet!Foo set = new WeakSet!Foo();

	void fn() {
		foreach (i; 0 .. desiredCount) {
			set.add(new Foo());
		}
	}

	void destroyStack() {
		ubyte[1024] _;
	}

	fn();
	destroyStack();
	assert(fooCount == desiredCount);
	assert(set.length == fooCount);

	set.lock();
	destroyStack();

	GC.collect();
	assert(fooCount == desiredCount);
	assert(set.length == fooCount);

	set.unlock();
	destroyStack();

	GC.collect();
	assert(fooCount == 0);
	assert(set.length == fooCount);
}

/++ Basic test +/
unittest {
	import std.random : uniform;

	GC.disable();

	int fooCount;

	class Foo {
		this() { fooCount += 1; }
		~this() { fooCount -= 1; }
	}

	WeakSet!Foo set = new WeakSet!Foo();

	void fn() {
		Foo a = new Foo();
		Foo b = new Foo();
		Foo c = new Foo();
		set.add(a);
		set.add(b);
		set.add(c);
		assert(set.length == 3);
		set.remove(c);
		assert(set.length == 2);

		// destroy any leftovers on the stack
		ubyte[1024] _;
	}

	fn();
	assert(fooCount == 3);
	assert(set.length == 2);

	set.lock();

	GC.collect();
	assert(fooCount == 2);
	assert(set.length == fooCount);

	set.unlock();

	GC.collect();
	assert(fooCount == 0);
	assert(set.length == fooCount);
}

/++ Create a random set and $(REF WeakSet), check that they match; remove some elements from the set, run a GC cycle, and check that they match +/
unittest {
	import std.random : uniform, partialShuffle;
	import std.array : array;

	GC.disable();

	int fooCount;

	class Foo {
		this() { fooCount += 1; }
		~this() { fooCount -= 1; }
	}

	bool[Foo] set;
	WeakSet!Foo weakSet = new WeakSet!Foo();

	void fn() {
		foreach (i; 0 .. uniform!"[]"(200, 3000)) {
			Foo f = new Foo();
			set[f] = true;
			weakSet.add(f);

			assert(set.length == weakSet.length);
		}
	}

	bool checkSetsEqual() {
		if (set.length != weakSet.length)
			return false;

		foreach (v; set.byKey)
			if (v !in weakSet)
				return false;

		foreach (v; weakSet)
			if (v !in set)
				return false;

		return true;
	}

	void subsetize() {
		size_t subsetSize = uniform!"[]"(1, set.length);

		// get a random subset of the desired size in the set
		foreach (v; set.byKey.array.partialShuffle(subsetSize)[subsetSize .. $]) {
			set.remove(v);
		}
	}

	void destroyStack() {
		ubyte[1024] _;
	}

	fn();

	destroyStack(); GC.collect();

	assert(checkSetsEqual);
	assert(set.length == fooCount);
	assert(weakSet.length == fooCount);

	subsetize();

	weakSet.lock();

	destroyStack(); GC.collect();

	assert(!checkSetsEqual);
	assert(set.length != fooCount);
	assert(weakSet.length == fooCount);

	weakSet.unlock();

	destroyStack(); GC.collect();

	assert(checkSetsEqual);
	assert(set.length == fooCount);
	assert(weakSet.length == fooCount);
}

/++ Test the actual set functionality of the $(REF WeakSet) class +/
unittest {
	import std.random : uniform, choice;
	import std.array : array;

	GC.disable();

	class Foo {}

	foreach (iter; 0 .. 10_000) {
		bool[Foo] set;
		WeakSet!Foo weakSet = new WeakSet!Foo();

		foreach (i; 0 .. uniform!"[]"(1, 300)) {
			int action = set.length == 0 ? 1 : uniform!"[]"(1, 2);

			if (action == 1) { // add
				Foo f = new Foo();
				set[f] = true;
				weakSet.add(f);
			}
			else if (action == 2) { // remove
				Foo randomFoo = set.byKey.array.choice;
				set.remove(randomFoo);
				weakSet.remove(randomFoo);
			}

			assert(set.length == weakSet.length);

			foreach (v; set.byKey)
				assert(v in weakSet);

			foreach (v; weakSet)
				assert(v in set);
		}
	}
}
