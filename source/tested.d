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
import std.datetime : StopWatch;
import std.string : startsWith;
import std.traits : isAggregateType, fullyQualifiedName;
import std.typetuple : TypeTuple;


/**
	Runs all unit tests contained in the given symbol recursively.

	composite can be a package, a module or a composite type.

	Example:
		This example assumes that the application has all of its sources in
		the package named "mypackage". All contained tests will be run
		recursively.

		---
		import tested;
		import mypackage.application;

		void main()
		{
			version(unittest) runUnitTests!mypackage(new ConsoleResultWriter);
			else runApplication;
		}
		---
*/
bool runUnitTests(alias composite)(TestResultWriter results)
{
	assert(!g_runner, "Running multiple unit tests concurrently is not supported.");
	g_runner = new TestRunner(results);
	auto ret = g_runner.runUnitTests!composite();
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
			writefln(`FAIL "%s" (%s) after %.6f s: %s`, m_name, m_qualifiedName, fracSecs(timestamp), error.msg);
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

	bool runUnitTests(alias composite)()
	{
		InstrumentStats basestats;
		m_running = false;
		m_quit = false;
		m_instrumentsReady = false;

		auto instrumentthr = new Thread(&instrumentThread);
		instrumentthr.name = "instrumentation thread";
		//instrumentthr.priority = Thread.PRIORITY_DEFAULT + 1;
		instrumentthr.start();

		auto ret = runUnitTestsImpl!composite();
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

	private bool runUnitTestsImpl(alias composite)()
	{
		bool ret = true;

		static if (composite.stringof.startsWith("module ") || isAggregateType!(typeof(composite))) {
			foreach (test; __traits(getUnitTests, composite)) {
				if (!runUnitTest!test())
					ret = false;
			}
		}

		// if composite has members, descent recursively
		static if (__traits(compiles, { auto mems = __traits(allMembers, composite); }))
			foreach (M; __traits(allMembers, composite)) {
				// stop on system types/modules and private members
				static if (!isSystemModule!(composite, M))
					static if (__traits(compiles, { auto tup = TypeTuple!(__traits(getMember, composite, M)); }))
						if (!runUnitTestsImpl!(__traits(getMember, composite, M))())
							ret = false;
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
		writeInstrumentStats(m_results, duration, m_baseStats, stats);

		synchronized (m_mutex) m_running = false;
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

private bool isSystemModule(alias composite, string mem)()
{
	return isSystemModule(fullyQualifiedName!(__traits(getMember, composite, mem)));
}

private bool isSystemModule()(string qualified_name)
{
	return qualified_name.startsWith("std.") ||
		qualified_name.startsWith("core.") ||
		qualified_name.startsWith("object.") ||
		qualified_name == "object";
}