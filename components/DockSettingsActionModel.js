.pragma library
function validId(value) {
  return typeof value === "string" && value.length <= 64
    && /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/.test(value)
    && ["constructor","prototype","__proto__"].indexOf(value) < 0
}
function validName(value) {
  return typeof value === "string" && value.trim().length > 0 && value.length <= 128
    && !/[\r\n\0]/.test(value)
}
function validSource(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 2048
    && !/[\r\n\0]/.test(value)
    && (value[0] === "/" || /^(https:\/\/|ssh:\/\/|git@)/.test(value))
}
function argumentsFor(action, data) {
  var args = data || ({})
  // Python itself exposes only this exact fixed operation list; no command
  // name, shell string or unvalidated input can be supplied by an editor.
  if (action === "create" && validId(args.id) && validName(args.name))
    return ["create","--id",args.id,"--name",args.name]
  if (["prepare-install","install"].indexOf(action) >= 0 && validSource(args.source))
    return [action,"--source",args.source]
  if (["launchers-add","launchers-remove"].indexOf(action) >= 0)
    return [action]
  return null
}
function replyFrom(text, exitCode) {
  try {
    var reply = JSON.parse(text)
    if (!reply || reply.apiVersion !== 1 || typeof reply.ok !== "boolean")
      return {ok:false,error:{code:"E_PROTOCOL",message:"Invalid action reply"}}
    if (exitCode !== 0 && reply.ok)
      return {ok:false,error:{code:"E_PROCESS",message:"Action process failed"}}
    return reply
  } catch (err) { return {ok:false,error:{code:"E_PROTOCOL",message:"Invalid action reply"}} }
}
