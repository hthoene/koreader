describe("Worker module", function()
    local Worker, buffer, ffiutil
    setup(function()
        require("commonrequire")
        Worker = require("worker")
        buffer = require("string.buffer")
        ffiutil = require("ffi/util")
    end)

    -- Run a task in a sub-process, and wait for its results.
    local function runInSubProcess(task)
        local pid, fd = Worker.runInSubProcess(task, true)
        assert.truthy(pid)
        local data = ffiutil.readAllFromFD(fd)
        ffiutil.isSubProcessDone(pid, true)
        if data == "" then
            return
        end
        local results = buffer.decode(data)
        return unpack(results, 1, results.n)
    end

    it("should describe tasks", function()
        local task = Worker.task("util", "splitFilePathName", "/a/b.epub", nil, false)
        assert.are.same({ module = "util", func = "splitFilePathName", n = 3, "/a/b.epub", nil, false }, task)
    end)

    it("should run tasks", function()
        assert.are.same({ "/a/", "b.epub" }, { Worker.runTask(Worker.task("util", "splitFilePathName", "/a/b.epub")) })
        -- Method.
        assert.is_true(Worker.runTask(Worker.task("luasettings", ":extend", { x = 1 })).x == 1)
    end)

    it("should run tasks in a sub-process", function()
        assert.are.same({ "/a/", "b.epub" }, { runInSubProcess(Worker.task("util", "splitFilePathName", "/a/b.epub")) })
        local t = { a = { 1, 2 }, s = "ü" }
        assert.are.same(t, runInSubProcess(Worker.task("util", "tableDeepCopy", t)))
    end)

    it("should report being in a sub-process", function()
        assert.is_false(Worker.isInSubProcess())
        assert.is_true(runInSubProcess(Worker.task("worker", "isInSubProcess")))
    end)

    it("should return nothing when the task fails", function()
        assert.is_nil(runInSubProcess(Worker.task("util", "doesNotExist")))
    end)
end)
