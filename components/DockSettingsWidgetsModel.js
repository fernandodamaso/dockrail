.pragma library
.import "DockSidebarWidgetModel.js" as WidgetModel

// Canonical list: enabled IDs keep their persisted order, including unknown IDs;
// registered but disabled Widgets follow under a single Off heading.
function rows(registry, requested, development) {
  var enabled=WidgetModel.requestedIds(requested)
  var registered=WidgetModel.registeredRows(registry)
  var lookup=Object.create(null)
  registered.forEach(function(row){lookup[row.id]=row})
  var out=[]
  enabled.forEach(function(id) {
    var row=lookup[id]
    // Enabled demo.* IDs stay visible in production as unavailable rows so the
    // persisted value can still be reviewed and removed; only the Off group
    // hides development widgets.
    var devHidden = !development && id.indexOf("demo.")===0
    out.push(Object.assign({},row||{
      id:id,label:id,description:"Widget unavailable on this installation",
      iconName:"alert-circle",available:false,manageable:false
    },{id:id,enabled:true,registered:!!row && !devHidden,unavailable:!row||row.available===false||devHidden,
      position:out.length+1,group:"enabled",
      label:id==="herdr.agents"?"Coding agents":(row ? row.label : id)}))
  })
  registered.forEach(function(row) {
    if (enabled.indexOf(row.id)>=0 || (!development && row.id.indexOf("demo.")===0)) return
    out.push(Object.assign({},row,{enabled:false,registered:true,unavailable:row.available===false,
      position:null,group:"off",label:row.id==="herdr.agents"?"Coding agents":row.label}))
  })
  return out
}
function moveSlot(order,id,delta) {
  var ids=WidgetModel.requestedIds(order)
  var index=ids.indexOf(id)
  if (index<0 || (delta<0 && index===0) || (delta>0 && index===ids.length-1))
    return -1
  return delta<0 ? index-1 : index+2
}
function limited(features) {
  return !!(features && features.herdrAgents && features.herdrAgents.runtime==="limited")
}
