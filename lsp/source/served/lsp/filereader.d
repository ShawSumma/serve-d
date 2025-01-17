module served.lsp.filereader;

import core.thread;
import core.sync.mutex;

import std.algorithm;
import std.stdio;

/// A simple file reader continuously reading into a 1 byte buffer and appending
/// it to the data. Ensures data is never buffered on any platform at the cost
/// of being a lot more CPU intensive.
class StdFileReader : FileReader
{
	this(File file)
	{
		super();
		this.file = file;
	}

	override void stop()
	{
		file.close();
	}

	override void run()
	{
		ubyte[1] buffer;
		while (!file.eof)
		{
			auto chunk = file.rawRead(buffer[]);
			synchronized (mutex)
				data ~= chunk;
		}
	}

	override bool isReading()
	{
		return isRunning && !file.eof;
	}

	File file;
}

/// A file reader implementation using the Win32 API using events. Reads as much
/// content as possible when new data is available at once, making the file
/// reading operation much more efficient when large chunks of data are being
/// transmitted.
version (Windows) class WindowsStdinReader : FileReader
{
	import core.sys.windows.windows;

	this()
	{
		super();
	}

	override void stop()
	{
		wantStop = true;
	}

	override void run()
	{
		auto stdin = GetStdHandle(STD_INPUT_HANDLE);
		INPUT_RECORD inputRecord;
		DWORD nbRead;
		ubyte[4096] buffer;

		while (!wantStop)
		{
			switch (WaitForSingleObject(stdin, 1000))
			{
			case WAIT_TIMEOUT:
				break;
			case WAIT_OBJECT_0:
				DWORD len;
				if (!ReadFile(stdin, &buffer, buffer.length, &len, null))
				{
					stderr.writeln("ReadFile failed ", GetLastError());
					break;
				}
				if (len == 0)
				{
					stderr.writeln("WindowsStdinReader EOF");
					return;
				}
				synchronized (mutex)
					data ~= buffer[0 .. len];
				break;
			case WAIT_FAILED:
				stderr.writeln("stdin read failed ", GetLastError());
				break;
			case WAIT_ABANDONED:
				stderr.writeln("stdin read wait was abandoned ", GetLastError());
				break;
			default:
				stderr.writeln("Unexpected WaitForSingleObject response");
				break;
			}
		}
	}

	override bool isReading()
	{
		return isRunning;
	}

	private bool wantStop;
}

/// A file reader implementation using the POSIX select API using events. Reads
/// as much content as possible when new data is available at once, making the
/// file reading operation much more efficient when large chunks of data are
/// being transmitted.
version (Posix) class PosixStdinReader : FileReader
{
	import core.stdc.errno;
	import core.sys.posix.sys.select;
	import core.sys.posix.sys.time;
	import core.sys.posix.sys.types;
	import core.sys.posix.unistd;

	override void stop()
	{
		stdin.close();
	}

	override void run()
	{

		ubyte[4096] buffer;
		scope (exit)
			stdin.close();

		while (!stdin.error && !stdin.eof)
		{
			fd_set rfds;
			timeval tv;

			FD_ZERO(&rfds);
			FD_SET(0, &rfds);

			tv.tv_sec = 1;

			auto ret = select(1, &rfds, null, null, &tv);

			if (ret == -1)
			{
				int err = errno;
				if (err == EINTR)
					continue;
				stderr.writeln("[fatal] PosixStdinReader error ", err, " in select()");
				break;
			}
			else if (ret)
			{
				auto len = read(0, buffer.ptr, buffer.length);
				if (len == -1)
				{
					int err = errno;
					if (err == EINTR)
						continue;
					stderr.writeln("PosixStdinReader error ", errno, " in read()");
					break;
				}
				else if (len == 0)
				{
					break; // eof
				}
				else
				{
					synchronized (mutex)
						data ~= buffer[0 .. len];
				}
			}
		}
	}

	override bool isReading()
	{
		return isRunning && !stdin.eof && !stdin.error;
	}
}

/// Base class for file readers which can read a file or standard handle line
/// by line in a Fiber context, yielding until a line is available.
abstract class FileReader : Thread
{
	this()
	{
		super(&run);
		mutex = new Mutex();
	}

	string yieldLine()
	{
		ptrdiff_t index;
		string ret;
		while (true)
		{
			bool hasData;
			synchronized (mutex)
			{
				index = data.countUntil([cast(ubyte) '\r', cast(ubyte) '\n']);
				if (index != -1)
				{
					ret = cast(string) data[0 .. index].dup;
					data = data[index + 2 .. $];
					break;
				}

				hasData = data.length != 0;
			}

			if (!hasData && !isReading)
				return ret.length ? ret : null;

			Fiber.yield();
		}
		return ret;
	}

	/// Yields until the specified length of data is available, then removes the
	/// data from the incoming data stream atomically and returns a duplicate of
	/// it.
	/// Returns null if the file reader stops while reading.
	ubyte[] yieldData(size_t length)
	{
		while (true)
		{
			bool hasData;
			synchronized (mutex)
			{
				if (data.length >= length)
				{
					auto ret = data[0 .. length].dup;
					data = data[length .. $];
					return ret;
				}

				hasData = data.length != 0;
			}

			if (!hasData && !isReading)
				return null;

			Fiber.yield();
		}
	}

	abstract void stop();
	abstract bool isReading();

protected:
	abstract void run();

	ubyte[] data;
	Mutex mutex;
}

/// Creates a new FileReader using the GC reading from stdin using a platform
/// optimized implementation or StdFileReader if none is available.
///
/// The created instance can then be started using the `start` method and
/// stopped at exit using the `stop` method.
///
/// Examples:
/// ---
/// auto input = newStdinReader();
/// input.start();
/// scope (exit)
///     input.stop();
/// ---
FileReader newStdinReader()
{
	version (Windows)
		return new WindowsStdinReader();
	else version (Posix)
		return new PosixStdinReader();
	else
		return new StdFileReader(stdin);
}

/// Reads a file into a given buffer with a specified maximum length. If the
/// file is bigger than the buffer, the buffer will be resized using the GC and
/// updated through the ref argument.
/// Params:
///   file = The filename of the file to read.
///   buffer = A GC allocated buffer that may be enlarged if it is too small.
///   maxLen = The maxmimum amount of bytes to read from the file.
/// Returns: The contents of the file up to maxLen or EOF. The data is a slice
/// of the buffer argument case to a `char[]`.
char[] readCodeWithBuffer(string file, ref ubyte[] buffer, size_t maxLen = 1024 * 50)
{
	auto f = File(file, "rb");
	size_t len = f.rawRead(buffer).length;
	if (f.eof)
		return cast(char[]) buffer[0 .. len];
	while (buffer.length * 2 < maxLen)
	{
		buffer.length *= 2;
		len += f.rawRead(buffer[len .. $]).length;
		if (f.eof)
			return cast(char[]) buffer[0 .. len];
	}
	if (buffer.length >= maxLen)
		return cast(char[]) buffer;
	buffer.length = maxLen;
	f.rawRead(buffer[len .. $]);
	return cast(char[]) buffer;
}
