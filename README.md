## What's a weak set?

A weak set allows you to store a set of items in a container, while not keeping the those items explicitly alive. If all references to an item--other than those references from a weakset--are gone, then the garbage collector will collect the item, and the item will be removed from all weaksets that it's in.

## Usage

```d
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
```
