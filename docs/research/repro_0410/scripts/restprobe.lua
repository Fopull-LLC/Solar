local acc, n, worst, maxp = 0, 0, 0, 0
function start(node) perf.enable(true) end
function update(node, dt)
  if time > 3 then
    acc, n = acc + perf.ms("particles"), n + 1
    worst = math.max(worst, perf.worstMs("particles"))
    maxp = math.max(maxp, perf.counts().particles or 0)
  end
end
function onDestroy() end
function lateUpdate(node, dt)
  if n == 400 then print(string.format("REST particles mean %.3f ms worst %.3f live %d", acc / n, worst, maxp)) end
end
