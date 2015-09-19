module app;

import tested;


void main()
{
	version (unittest) {} else {
		import std.stdio;
		writeln(`This application does nothing. Run with "dub --build=unittest"`);
	}
}

shared static this()
{
	version (unittest) {
		import core.runtime;
		Runtime.moduleUnitTester = () => true;
		runUnitTests!app(new JsonTestResultWriter("results.json"));
		runUnitTests!app(new ConsoleTestResultWriter);
		assert(runUnitTests!app(new PrettyConsoleTestResultWriter), "Unit tests failed.");
	}
}


@name("arithmetic")
unittest {
	int i = 3;
	assert(i == 3);
	i *= 2;
	assert(i == 6);
	i += 5;
	assert(i == 11);
}

@name("arithmetic2")
unittest {
	int i = 3;
	i += 10;
	assert(i == 11); // fail
}

@name("int array")
unittest {
	import core.thread;

	int[] ints;
	foreach (i; 0 .. 1000) {
		ints ~= i;
		Thread.sleep(1.msecs);
		assert(ints.length == i+1);
	}
	assert(ints.length == 1000);
}

@name("limited int array")
unittest {
	import core.thread;

	int[] ints;
	foreach (i; 0 .. 1000) {
		ints ~= i;
		Thread.sleep(1.msecs);
		assert(ints.length == i+1);
		assert(ints.length < 900, "Too many items");
	}
}
