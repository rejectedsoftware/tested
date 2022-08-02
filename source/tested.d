/**
	Unit test runner with structured result output support.

	Copyright: Copyright ©2013 rejectedsoftware e.K., all rights reserved.
	Authors: Sönke Ludwig
*/
module tested;

import core.sync.condition;
import core.sync.mutex;
import core.memory;
import core.time;
import core.thread;
import std.datetime.stopwatch : StopWatch;
import std.string : startsWith;
import std.traits;
import std.typetuple : TypeTuple;


/**
	Runs all unit tests contained in the given symbol recursively.

	COMPOSITES can be a list of modules or composite types.

	Example:
		This example assumes that the application has all of its sources in
		the package named "mypackage". All contained tests will be run
		recursively.

		---
		import tested;
		import mypackage.application;

		void main()
		{
			version(unittest) runUnitTests!(mypackage.application)(new ConsoleResultWriter);
			else runApplication;
		}
		---
*/
bool runUnitTests(COMPOSITES...)(TestResultWriter results)
{
	assert(!g_runner, "Running multiple unit tests concurrently is not supported.");
	g_runner = new TestRunner(results);
	auto ret = g_runner.runUnitTests!COMPOSITES();
	g_runner = null;
	return ret;
}


/**
	Emits a custom instrumentation value that will be stored in the unit test results.
*/
void instrument(string name, double value)
{
	if (g_runner) g_runner.instrument(name, value);
}


/**
	Attribute for giving a unit test a name.

	The name of a unit test will be output in addition to the fully
	qualified name of the test function in the test output.

	Example:
		---
		@name("some test")
		unittest {
			// unit test code
		}

		@name("some other test")
		unittest {
			// unit test code
		}
		---	
*/
struct name { string name; }


/**
	Base interface for all unit test result writers.
*/
interface TestResultWriter {
	void finalize();
	void beginTest(string name, string qualified_name);
	void addScalar(Duration timestamp, string name, double value);
	void endTest(Duration timestamp, Throwable error);
}


/**
	Directly outputs unit test results to the console.
*/
class ConsoleTestResultWriter : TestResultWriter {
	import std.stdio;
	private {
		size_t m_failCount, m_successCount;
		string m_name, m_qualifiedName;
	}

	void finalize()
	{
		writefln("===========================");
		writefln("%s of %s tests have passed.", m_successCount, m_successCount+m_failCount);
		writefln("");
		writefln("FINAL RESULT: %s", m_failCount > 0 ? "FAILED" : "PASSED");
	}

	void beginTest(string name, string qualified_name)
	{
		m_name = name;
		m_qualifiedName = qualified_name;
	}

	void addScalar(Duration timestamp, string name, double value)
	{
	}

	void endTest(Duration timestamp, Throwable error)
	{
		if (error) {
			version(Posix) write("\033[1;31m");
			writefln(`FAIL "%s" (%s) after %.6f s: %s`, m_name, m_qualifiedName, fracSecs(timestamp), error.msg);
			version(Posix) write("\033[0m");
			m_failCount++;
		} else {
			writefln(`PASS "%s" (%s) after %.6f s`, m_name, m_qualifiedName, fracSecs(timestamp));
			m_successCount++;
		}
	}

	static double fracSecs(Duration dur)
	{
		return 1E-6 * dur.total!"usecs";
	}
}

/**
	Outputs test results and instrumentation values 
*/
class JsonTestResultWriter : TestResultWriter {
	import std.stdio;

	private {
		File m_file;
		bool m_gotInstrumentValue, m_gotUnitTest;
	}

	this(string filename)
	{
		m_file = File(filename, "w+b");
		m_file.writeln("[");
		m_gotUnitTest = false;
	}

	void finalize()
	{
		m_file.writeln();
		m_file.writeln("]");
		m_file.close();
	}

	void beginTest(string name, string qualified_name)
	{
		if (m_gotUnitTest) m_file.writeln(",");
		else m_gotUnitTest = true;
		m_file.writef(`{"name": "%s", "qualifiedName": "%s", "instrumentation": [`, name, qualified_name);
		m_gotInstrumentValue = false;
	}

	void addScalar(Duration timestamp, string name, double value)
	{
		if (m_gotInstrumentValue) m_file.write(", ");
		else m_gotInstrumentValue = true;
		m_file.writef(`{"name": "%s", "value": %s, "timestamp": %s}`, name, value, timestamp.total!"usecs" * 1E-6);
	}

	void endTest(Duration timestamp, Throwable error)
	{
		m_file.writef(`], "success": %s, "duration": %s`, error is null, timestamp.total!"usecs" * 1E-6);
		if (error) m_file.writef(`, "message": "%s"`, error.msg);
		m_file.write("}");
	}
}

private class TestRunner {
	private {
		Mutex m_mutex;
		Condition m_condition;
		TestResultWriter m_results;
		InstrumentStats m_baseStats;
		bool m_running, m_quit, m_instrumentsReady;
		StopWatch m_stopWatch;
	}

	this(TestResultWriter writer)
	{
		m_results = writer;
		m_mutex = new Mutex;
		m_condition = new Condition(m_mutex);
	}

	bool runUnitTests(COMPOSITES...)()
	{
		InstrumentStats basestats;
		m_running = false;
		m_quit = false;
		m_instrumentsReady = false;

		auto instrumentthr = new Thread(&instrumentThread);
		instrumentthr.name = "instrumentation thread";
		//instrumentthr.priority = Thread.PRIORITY_DEFAULT + 1;
		instrumentthr.start();

		bool[string] visitedMembers;
		auto ret = true;
		foreach(comp; COMPOSITES)
			if (!runUnitTestsImpl!comp(visitedMembers))
				ret = false;
		m_results.finalize();

		synchronized (m_mutex) m_quit = true;
		m_condition.notifyAll();
		instrumentthr.join();

		return ret;
	}

	private void instrument(string name, double value)
	{
		auto ts = cast(Duration)m_stopWatch.peek();
		synchronized (m_mutex) m_results.addScalar(ts, name, value);
	}

	private bool runUnitTestsImpl(COMPOSITE...)(ref bool[string] visitedMembers)
		if (COMPOSITE.length == 1 && isUnitTestContainer!COMPOSITE)
	{
		bool ret = true;
		//pragma(msg, fullyQualifiedName!COMPOSITE);

		foreach (test; __traits(getUnitTests, COMPOSITE)) {
			if (!runUnitTest!test())
				ret = false;
		}
		// if COMPOSITE has members, descent recursively
		static if (isUnitTestContainer!COMPOSITE) {
			foreach (M; __traits(allMembers, COMPOSITE)) {
				static if (
					__traits(compiles, __traits(getMember, COMPOSITE, M)) &&
					isSingleField!(__traits(getMember, COMPOSITE, M)) &&
					isUnitTestContainer!(__traits(getMember, COMPOSITE, M)) &&
					!isModule!(__traits(getMember, COMPOSITE, M))
					)
				{
					// Don't visit the same member again.
					// This can be checked at compile time, but it's easier and much much
					// faster at runtime.
					if (__traits(getMember, COMPOSITE, M).mangleof !in visitedMembers)
					{ 
						visitedMembers[__traits(getMember, COMPOSITE, M).mangleof] = true;
						if (!runUnitTestsImpl!(__traits(getMember, COMPOSITE,	M))(visitedMembers))
							ret = false;
					}
				}
			}
		}

		return ret;
	}

	private bool runUnitTest(alias test)()
	{
		string name;
		foreach (att; __traits(getAttributes, test))
			static if (is(typeof(att) == .name))
				name = att.name;

		// wait for instrumentation thread to get ready
		synchronized (m_mutex)
			while (!m_instrumentsReady)
				m_condition.wait();

		m_results.beginTest(name, fullyQualifiedName!test);
		m_stopWatch.reset();

		GC.collect();
		m_baseStats = InstrumentStats.instrument();

		synchronized (m_mutex) m_running = true;
		m_condition.notifyAll();

		Throwable error;
		try {
			m_stopWatch.start();
			test();
			m_stopWatch.stop();
		} catch (Throwable th) {
			m_stopWatch.stop();
			error = th;
		}

		auto duration = cast(Duration)m_stopWatch.peek();

		auto stats = InstrumentStats.instrument();
		synchronized (m_mutex) {
			writeInstrumentStats(m_results, duration, m_baseStats, stats);
			m_running = false;
		}
			
		m_results.endTest(duration, error);
		return error is null;
	}

	private void instrumentThread()
	{
		while (true) {
			synchronized (m_mutex) {
				if (m_quit) return;
				if (!m_running) {
					m_instrumentsReady = true;
					m_condition.notifyAll();
					while (!m_running && !m_quit) m_condition.wait();
					if (m_quit) return;
					m_instrumentsReady = false;
				}
			}

			Thread.sleep(10.msecs);

			auto ts = cast(Duration)m_stopWatch.peek;
			auto stats = InstrumentStats.instrument();
			synchronized (m_mutex)
				if (m_running)
					writeInstrumentStats(m_results, ts, m_baseStats, stats);
		}
	}
}


// copied from gc.stats
private struct GCStats {
    size_t poolsize;        // total size of pool
    size_t usedsize;        // bytes allocated
    size_t freeblocks;      // number of blocks marked FREE
    size_t freelistsize;    // total of memory on free lists
    size_t pageblocks;      // number of blocks marked PAGE
}

// from gc.proxy
private extern (C) GCStats gc_stats();

private struct InstrumentStats {
	size_t gcPoolSize;
	size_t gcUsedSize;
	size_t gcFreeListSize;

	static InstrumentStats instrument()
	{
		auto stats = gc_stats();
		InstrumentStats ret;
		ret.gcPoolSize = stats.poolsize;
		ret.gcUsedSize = stats.usedsize;
		ret.gcFreeListSize = stats.freelistsize;
		return ret;
	}
}

private {
	__gshared TestRunner g_runner;
}

private void writeInstrumentStats(TestResultWriter results, Duration timestamp, InstrumentStats base_stats, InstrumentStats stats)
{
	results.addScalar(timestamp, "gcPoolSize", stats.gcPoolSize - base_stats.gcPoolSize);
	results.addScalar(timestamp, "gcUsedSize", stats.gcUsedSize - base_stats.gcUsedSize);
	results.addScalar(timestamp, "gcFreeListSize", stats.gcFreeListSize - base_stats.gcFreeListSize);
}

private template isUnitTestContainer(DECL...)
	if (DECL.length == 1)
{
	static if (!isAccessible!DECL) {
		enum isUnitTestContainer = false;
	} else static if (is(FunctionTypeOf!(DECL[0]))) {
		enum isUnitTestContainer = false;
	} else static if (is(DECL[0]) && !isAggregateType!(DECL[0])) {
		enum isUnitTestContainer = false;
	} else static if (isPackage!(DECL[0])) {
		enum isUnitTestContainer = false;
	} else static if (isModule!(DECL[0])) {
		enum isUnitTestContainer = DECL[0].stringof != "module object";
	} else static if (!__traits(compiles, fullyQualifiedName!(DECL[0]))) {
		enum isUnitTestContainer = false;
	} else static if (!is(typeof(__traits(allMembers, DECL[0])))) {
		enum isUnitTestContainer = false;
	} else {
		enum isUnitTestContainer = true;
	}
}

private template isModule(DECL...)
	if (DECL.length == 1)
{
	static if (is(DECL[0])) enum isModule = false;
	else static if (is(typeof(DECL[0])) && !is(typeof(DECL[0]) == void)) enum isModule = false;
	else static if (!is(typeof(DECL[0].stringof))) enum isModule = false;
	else static if (is(FunctionTypeOf!(DECL[0]))) enum isModule = false;
	else enum isModule = DECL[0].stringof.startsWith("module ");
}

private template isPackage(DECL...)
	if (DECL.length == 1)
{
	static if (is(DECL[0])) enum isPackage = false;
	else static if (is(typeof(DECL[0])) && !is(typeof(DECL[0]) == void)) enum isPackage = false;
	else static if (!is(typeof(DECL[0].stringof))) enum isPackage = false;
	else static if (is(FunctionTypeOf!(DECL[0]))) enum isPackage = false;
	else enum isPackage = DECL[0].stringof.startsWith("package ");
}

private template isAccessible(DECL...)
	if (DECL.length == 1)
{
	enum isAccessible = __traits(compiles, testTempl!(DECL[0])());
}

private template isSingleField(DECL...)
{
	enum isSingleField = DECL.length == 1;
}


static assert(!is(tested));
static assert(isModule!tested);
static assert(!isPackage!tested);
static assert(isPackage!std);
static assert(__traits(compiles, testTempl!GCStats()));
static assert(__traits(compiles, testTempl!(immutable(ubyte)[])));
static assert(isAccessible!GCStats);
static assert(isUnitTestContainer!GCStats);
static assert(isUnitTestContainer!tested);

private void testTempl(X...)()
	if (X.length == 1)
{
	static if (is(X[0])) {
		auto x = X[0].init;
	} else {
		auto x = X[0].stringof;
	}
}
