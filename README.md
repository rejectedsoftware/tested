tested
======

This is a simple unit test runner with the ability to measure resource usage of each test. It can produce structured test result and resource data especially suitable for automated tests and performance/resource monitoring.

To use it, simply disable D's built-in unit test runner and call `runUnitTests`. Your `main()` should just return zero or be declared as `void` and do nothing else:

```
version (unittest) {
	shared static this()
	{
		// disable built-in unit test runner
		import core.runtime;
		Runtime.moduleUnitTester = () => true;
	}

	void main()
	{
		enforce(runUnitTests!app(new JsonTestResultWriter("results.json")), "Unit tests failed.");
	}
}
```

Alternatively, the latest version of [DUB](http://code.dlang.org/download) will automatically generate the necessary code by simply running "dub test" on your project. The package description just needs to have a dependency to "tested".


Example output
--------------

Running the included example with `dub --build=unittest` will produce output similar to this:

```
$ dub --build=unittest
Checking dependencies in 'C:\Users\sludwig\Develop\tested\example'
Building configuration "application", build type unittest
Compiling...
Linking...
Running tested-example.exe
PASS "arithmetic" (app.__unittestL26_1) after 0.000000 s
FAIL "arithmetic2" (app.__unittestL36_2) after 0.015825 s: unittest failure
PASS "int array" (app.__unittestL43_3) after 1.936194 s
FAIL "limited int array" (app.__unittestL56_4) after 1.741268 s: Too many items
===========================
2 of 4 tests have passed.

FINAL RESULT: FAILED
core.exception.AssertError@source\app.d(20): Unit tests failed.
```

It will also generate a results.json file with detailed data, similar to this (shortened):

```
[
	{
		"name": "arithmetic",
		"qualifiedName": "app.__unittestL26_1",
		"instrumentation": [
			{"name": "gcPoolSize", "value": 0, "timestamp": 0},
			{"name": "gcUsedSize", "value": 0, "timestamp": 0},
			{"name": "gcFreeListSize", "value": 0, "timestamp": 0}
		],
		"success": true,
		"duration": 0
	},
	{
		"name": "arithmetic2",
		"qualifiedName": "app.__unittestL36_2",
		"instrumentation": [
			{"name": "gcPoolSize", "value": 0, "timestamp": 0.010737},
			{"name": "gcUsedSize", "value": 96, "timestamp": 0.010737},
			{"name": "gcFreeListSize", "value": 4.29497e+09, "timestamp": 0.010737},
			...
			{"name": "gcPoolSize", "value": 0, "timestamp": 0.0347},
			{"name": "gcUsedSize", "value": 592, "timestamp": 0.0347},
			{"name": "gcFreeListSize", "value": 7600, "timestamp": 0.0347}
		],
		"success": false,
		"duration": 0.0347,
		"message": "unittest failure"
	},
	{
		"name": "int array",
		"qualifiedName": "app.__unittestL43_3",
		"instrumentation": [
			{"name": "gcPoolSize", "value": 0, "timestamp": 0.010654},
			{"name": "gcUsedSize", "value": 48, "timestamp": 0.010654},
			{"name": "gcFreeListSize", "value": 4048, "timestamp": 0.010654},
			...
			{"name": "gcPoolSize", "value": 1.04858e+06, "timestamp": 1.9594},
			{"name": "gcUsedSize", "value": 2064, "timestamp": 1.9594},
			{"name": "gcFreeListSize", "value": 6128, "timestamp": 1.9594}
		],
		"success": true,
		"duration": 1.9594
	},
	{
		"name": "limited int array",
		"qualifiedName": "app.__unittestL56_4",
		"instrumentation": [
			{"name": "gcPoolSize", "value": 0, "timestamp": 0.010421},
			{"name": "gcUsedSize", "value": 48, "timestamp": 0.010421},
			{"name": "gcFreeListSize", "value": 4048, "timestamp": 0.010421},
			...
			{"name": "gcPoolSize", "value": 0, "timestamp": 1.76025},
			{"name": "gcUsedSize", "value": 4416, "timestamp": 1.76025},
			{"name": "gcFreeListSize", "value": 11968, "timestamp": 1.76025}
		],
		"success": false,
		"duration": 1.76025,
		"message": "Too many items"
	}
]
```
