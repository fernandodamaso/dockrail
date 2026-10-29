import QtQuick
import QtTest
import "../components"

TestCase {
  id: suite
  name: "SettingsFeatures"
  when: windowShown
  width: 760
  height: 620
  visible: true

  readonly property var metadata: ({settings:{
    browserProfileBadgesEnabled:{ui:{feature:{
      id:"chrome",keys:["browserProfileBadgesEnabled","sidebarBrowserTabsEnabled"],
      on:{browserProfileBadgesEnabled:true,sidebarBrowserTabsEnabled:true},
      off:{browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:false}}}},
    sidebarWidgets:{ui:{feature:{
      id:"coding-agents",keys:["sidebarWidgets","dockHerdrIndicators"],
      widgetId:"herdr.agents",membership:"append-or-remove-id",
      on:{dockHerdrIndicators:true},off:{dockHerdrIndicators:false}}}},
    launcherBadgeMode:{ui:{feature:{
      id:"launcher-counts",keys:["launcherBadgeMode"],
      on:{launcherBadgeMode:"automatic"},off:{launcherBadgeMode:"dots-only"}}}}
  }})
  Component {
    id: hostFactory
    Item {
      property var settings: ({
        browserProfileBadgesEnabled:false,sidebarBrowserTabsEnabled:false,
        sidebarWidgets:["custom.widget"],dockHerdrIndicators:false,
        launcherBadgeMode:"dots-only"
      })
      property bool settingsLoaded:true
      property bool settingsReloadPending:false
      property string settingsLoadState:"loaded"
      property string settingsWriteState:"saved"
      property var writes:[]
      property var nextResult:null
      property QtObject featureReadinessBridge: QtObject {
        property var lastGoodFeatures: ({
          chromeProfilesTabs:{configuration:"partly-on",installation:"installed",runtime:"ready",
            nextAction:{kind:"enable",text:"Enable Chrome"}},
          herdrAgents:{configuration:"off",installation:"installed",runtime:"limited",
            reason:"Herdr 0.8.2 requires 0.9.1 for focus",
            nextAction:{kind:"configure",text:"Upgrade Herdr"}},
          launcherCounts:{configuration:"off",installation:"missing",runtime:"unavailable",
            nextAction:{kind:"install",text:"Install provider"}},
          agentLaunchers:{configuration:"off",installation:"missing",runtime:"unavailable",
            nextAction:{kind:"install",text:"Add launchers"},agents:[
              {label:"Claude Code",command:"claude",found:true,launcherInstalled:false},
              {label:"Pi",command:"pi",found:false,launcherInstalled:false}
            ]}
        })
        property string lastError:""
        property bool panelVisible:false
        property int refreshCount:0
        function refresh(){refreshCount++;return true}
      }
      property QtObject settingsActions: QtObject {
        property bool inFlight:false
        property string status:"idle"
        property string errorCode:""
        property string errorText:""
        property var result:null
        property var calls:[]
        function manageLaunchers(add){
          calls=calls.concat([add])
          return {accepted:true}
        }
      }
      property QtObject settingsPanel: QtObject {
        property string selectedSection:""
        function selectSection(id){selectedSection=id;return true}
      }
      function saveSettingsIntent(patch,expected){
        for(var key in patch){
          if(JSON.stringify(settings[key])!==JSON.stringify(expected[key]))
            return {accepted:false,reply:{ok:false,error:{code:"E_STALE",message:"Changed"}}}
        }
        if(nextResult)return nextResult
        writes=writes.concat([{patch:patch,expected:expected}])
        settings=Object.assign({},settings,patch)
        return {accepted:true,reply:{ok:true,data:{applied:true,persisted:true}}}
      }
    }
  }
  Component {id:sectionFactory;DockSettingsFeaturesSection {}}
  function makeSection(){
    var host=createTemporaryObject(hostFactory,suite)
    var section=createTemporaryObject(sectionFactory,host,{host:host,metadata:metadata,panelActive:true,width:460})
    verify(section!==null)
    return section
  }
  function test_badges_are_independent_of_switches(){
    var section=makeSection()
    compare(section.targets.length,4)
    compare(findChild(section,"feature-card-chrome").status,"Ready")
    compare(findChild(section,"feature-card-coding-agents").status,"Limited")
    compare(findChild(section,"feature-card-launcher-counts").status,"Not set up")
    compare(findChild(section,"feature-card-agent-launchers").status,"Not set up")
    compare(findChild(section,"feature-card-chrome").state,"off",
      "readiness must not decide configuration")
    verify(findChild(section,"feature-card-launcher-counts").canToggle)
    verify(section.toggleFeature("launcher-counts"))
    compare(section.host.settings.launcherBadgeMode,"automatic")
    compare(findChild(section,"feature-card-launcher-counts").status,"Not set up")
  }
  function test_mixed_switch_commits_one_atomic_patch(){
    var section=makeSection()
    section.host.settings=Object.assign({},section.host.settings,{browserProfileBadgesEnabled:true})
    compare(findChild(section,"feature-card-chrome").state,"partly-on")
    verify(section.toggleFeature("chrome"))
    compare(section.host.writes.length,1)
    compare(section.host.settings.browserProfileBadgesEnabled,true)
    compare(section.host.settings.sidebarBrowserTabsEnabled,true)
    verify(section.toggleFeature("chrome"))
    compare(section.host.writes.length,2)
    compare(section.host.settings.browserProfileBadgesEnabled,false)
    compare(section.host.settings.sidebarBrowserTabsEnabled,false)
  }
  function test_herdr_appends_and_removes_without_reordering(){
    var section=makeSection()
    verify(section.toggleFeature("coding-agents"))
    compare(section.host.settings.sidebarWidgets.join(","),"custom.widget,herdr.agents")
    compare(section.host.settings.dockHerdrIndicators,true)
    verify(section.toggleFeature("coding-agents"))
    compare(section.host.settings.sidebarWidgets.join(","),"custom.widget")
    compare(section.host.settings.dockHerdrIndicators,false)
  }
  function test_rejected_write_does_not_mutate_requested_state(){
    var section=makeSection()
    section.host.nextResult={accepted:false,reply:{ok:false,error:{code:"E_STALE",message:"Changed"}}}
    verify(!section.toggleFeature("chrome"))
    compare(section.host.writes.length,0)
    compare(section.host.settings.browserProfileBadgesEnabled,false)
    verify(section.feedback.indexOf("E_STALE")>=0)
  }
  function test_copy_only_setup_does_not_start_actions(){
    var section=makeSection()
    compare(section.focusFeature("launcher-counts"),true)
    compare(section.copyCommand(),"dockrail setup --feature launcher-counts")
    compare(section.host.settingsActions.calls.length,0)
    compare(section.host.writes.length,0)
    section.focusFeature("coding-agents")
    compare(section.copyCommand(),"dockrail setup --feature herdr")
    compare(section.host.settingsActions.calls.length,0)
  }
  function test_launcher_buttons_use_typed_broker_and_refresh(){
    var section=makeSection()
    verify(section.manageLaunchers(true))
    compare(section.host.settingsActions.calls.length,1)
    compare(section.host.settingsActions.calls[0],true)
    section.host.settingsActions.result={data:{launchers:{preserved:[]}}}
    section.host.settingsActions.status="success"
    compare(section.host.featureReadinessBridge.refreshCount,1)
    verify(section.manageLaunchers(false))
    compare(section.host.settingsActions.calls.length,2)
    compare(section.host.settingsActions.calls[1],false)
    compare(section.host.writes.length,0)
  }
  function test_read_only_blocks_all_writes(){
    var section=makeSection()
    section.host.settingsLoadState="invalid"
    verify(!section.toggleFeature("chrome"))
    verify(!section.manageLaunchers(true))
    compare(section.host.writes.length,0)
    compare(section.host.settingsActions.calls.length,0)
  }
}
