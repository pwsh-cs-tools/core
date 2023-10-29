#nullable enable
using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;

namespace ThreadExtensions;
public class Dispatcher : IDisposable
{
    internal static ConcurrentDictionary<Thread, Dispatcher> _dispatchers = new ConcurrentDictionary<Thread, Dispatcher>();

    private readonly Thread _initialThread;
    private readonly AutoResetEvent _taskAvailable = new AutoResetEvent(false);
    private readonly ConcurrentQueue<Task> _tasks = new ConcurrentQueue<Task>();
    private bool _running = false;
    private CancellationToken? Token;

    public bool Cancelled => Token != null && Token.Value.IsCancellationRequested;
    public bool Running => _running;

    public bool CheckAccess()
    {
        return Thread.CurrentThread == _initialThread;
    }

    public void VerifyAccess()
    {
        if (!CheckAccess())
        {
            throw new InvalidOperationException("This method can only be called on the thread that created the dispatcher.");
        }
    }

    public Dispatcher() : this(Thread.CurrentThread)    
    {}

    internal Dispatcher( Thread initialThread )
    {
        _initialThread = initialThread;
        _dispatchers.GetOrAdd(initialThread, this);
    }

    public void Run(CancellationToken token)
    {
        VerifyAccess();

        if (_running) throw new InvalidOperationException("The dispatcher is already running.");

        _running = true;

        Token = token;

        if(!_tasks.IsEmpty) _taskAvailable.Set();

        try
        {
            while (!Cancelled)
            {
                if (_taskAvailable.WaitOne(100)) // Wait for a task or a cancellation request
                {
                    while (!Cancelled && _tasks.TryDequeue(out var task))
                    {
                        try
                        {
                            task.RunSynchronously();
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"Exception in dispatched action: {ex}");
                        }
                    }
                }
            }
        }
        finally
        {
            Token = null;
            if(!_tasks.IsEmpty) _taskAvailable.Set(); // Ensure that any pending Invoke operations complete
            _running = false;
        }
    }

    public Task<TResult> InvokeAsync<TResult>(Func<TResult> function)
    {
        if (function == null) throw new ArgumentNullException(nameof(function));

        var tcs = new TaskCompletionSource<TResult>();

        Action wrapperAction = () => 
        {
            try
            {
                tcs.SetResult(function());
            }
            catch (Exception ex)
            {
                tcs.SetException(ex);
            }
        };

        _tasks.Enqueue(new Task(wrapperAction));
        if (_running && !Cancelled) _taskAvailable.Set();
        return tcs.Task;
    }

    public Task InvokeAsync(Delegate action)
    {
        if (action == null) throw new ArgumentNullException(nameof(action));

        // Attempt to convert the delegate to a Func<object>
        if (action is Func<object> func)
        {
            return InvokeAsync(func);
        }

        // If the delegate is not a Func<object>, try to create a Func<object> that calls the delegate
        var tcs = new TaskCompletionSource<object>();

        Action wrapperAction = () =>
        {
            try
            {
                var result = action.DynamicInvoke();
                // explicitly handle Possible null reference argument
                if (result != null)
                {
                    tcs.SetResult(result);
                }
            }
            catch (Exception ex)
            {
                tcs.SetException(ex);
            }
        };

        _tasks.Enqueue(new Task(wrapperAction));
        if (_running && !Cancelled) _taskAvailable.Set();
        return tcs.Task;
    }

    public void Dispose()
    {
        while (_running)
        {
            Thread.Sleep(100);
        }
        _taskAvailable.Dispose();
    }
}

public static class ThreadExtensions
{
    public static Dispatcher GetDispatcher(this Thread thread)
    {
        if (thread == null) throw new ArgumentNullException(nameof(thread));

        Dispatcher? dispatcher = null;
        
        Dispatcher._dispatchers.TryGetValue(thread, out dispatcher);

        if (dispatcher == null)
        {
            dispatcher = new Dispatcher(thread);
        }

        return dispatcher;
    }
}
