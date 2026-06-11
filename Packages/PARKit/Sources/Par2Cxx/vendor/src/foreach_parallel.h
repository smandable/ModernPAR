#ifndef __FOREACH_PARALLEL_H__
#define __FOREACH_PARALLEL_H__

#include <functional>
#include <thread>
#include <atomic>
#include <mutex>
#include <future>

// MODERNPAR PATCH (the only modified vendor file — see ../VENDORED.txt):
// Upstream runs `fn` on bare std::thread workers, so an exception escaping `fn` calls
// std::terminate, and the std::async path uses wait() (not get()), which silently swallows
// stored exceptions. ModernPAR's cancellation works by throwing from the output streambuf
// on whichever thread next writes progress, so worker exceptions must propagate: capture the
// first exception, stop handing out further items, join everyone, and rethrow on the calling
// thread. Behavior on the success path is unchanged.
template <class T>
void foreach_parallel(const std::vector<T> &collection, u32 numThreads, const std::function<void(const T&)> &fn)
{
  if (numThreads == 1 || collection.size() == 1)
  {
    for (const auto &item : collection)
      fn(item);
  }
  else if (numThreads >= collection.size())
  {
    // spawn a thread for each item
    std::vector<std::future<void>> tasks;
    tasks.reserve(collection.size());
    for (const auto &item : collection)
      tasks.push_back(std::async(std::launch::async, std::bind(fn, std::ref(item))));
    std::exception_ptr firstError = nullptr;
    for (auto &task : tasks)
    {
      try { task.get(); }
      catch (...) { if (!firstError) firstError = std::current_exception(); }
    }
    if (firstError) std::rethrow_exception(firstError);
  }
  else
  {
    std::atomic<unsigned> itemPos(0);
    std::atomic<bool> stop(false);
    std::mutex errorMutex;
    std::exception_ptr firstError = nullptr;
    std::vector<std::thread> threads;
    threads.reserve(numThreads);
    try
    {
      for (unsigned thread = 0; thread < numThreads; thread++)
      {
        threads.emplace_back([&itemPos, &collection, &fn, &stop, &errorMutex, &firstError]()
        {
          while (!stop.load(std::memory_order_relaxed))
          {
            unsigned i = itemPos.fetch_add(1, std::memory_order_relaxed);
            if (i >= collection.size()) break;
            try { fn(collection.at(i)); }
            catch (...)
            {
              std::lock_guard<std::mutex> lock(errorMutex);
              if (!firstError) firstError = std::current_exception();
              stop.store(true, std::memory_order_relaxed);
            }
          }
        });
      }
    }
    catch (...)
    {
      // Thread-creation failure mid-spawn: stop and join the workers that DID start
      // (letting joinable std::threads unwind calls std::terminate), then rethrow.
      stop.store(true, std::memory_order_relaxed);
      for (auto &thread : threads)
        thread.join();
      throw;
    }
    for (auto &thread : threads)
      thread.join();
    if (firstError) std::rethrow_exception(firstError);
  }
}

#endif // __FOREACH_PARALLEL_H__
