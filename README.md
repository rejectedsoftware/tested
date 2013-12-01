tested
======

This is a simple unit test runner with the ability to measure resource usage of each test. It can produce structured test result and resource data especially suitable for automated tests and performance/resource monitoring.

To use it, simply disable D's built-in unit test runner and call `runUnitTests`. Your `main()` should just return zero or be declared as `void` and do nothing else:

```
version (unittest) {
	shared static this()
	{
		import core.runtime;
		Runtime.moduleUnitTester = () => true;
		runUnitTests!app(new JsonTestResultWriter("results.json"));
		assert(runUnitTests!app(new ConsoleTestResultWriter), "Unit tests failed.");
	}

	void main()
	{
	}
}
```

Alternatively, the latest version of [DUB](http://code.dlang.org/download) will automatically generate the necessary code by simply running "dub test" on your project. The package description just needs to have a dependency to "tested".