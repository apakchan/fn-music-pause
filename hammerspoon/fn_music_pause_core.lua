local M = {}

function M.newController(player)
  return {
    fnDown = false,
    pausedToken = nil,
    player = player,
  }
end

function M.handleFnFlag(controller, isDown)
  if controller.fnDown == isDown then
    return
  end

  controller.fnDown = isDown

  if isDown then
    controller.pausedToken = controller.player:pauseIfPlaying()
    return
  end

  if controller.pausedToken ~= nil then
    controller.player:resume(controller.pausedToken)
    controller.pausedToken = nil
  end
end

return M
