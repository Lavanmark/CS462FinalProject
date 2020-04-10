ruleset driver_manager {
  meta {
    use module io.picolabs.wrangler alias wrangler
    shares __testing, get_drivers, get_peers
    provides get_drivers
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_drivers", "args": ["num_drivers"] },
        { "name": "get_peers", "args": ["self_name"]}
      ] , "events":
      [ { "domain": "flower_delivery", "type": "new_driver", "attrs": ["Driver Name", "location"]},
        { "domain": "flower_delivery", "type": "remove_driver", "attrs": ["Driver Name"]},
        { "domain": "flower_delivery", "type": "remove_all_drivers"}
      ]
    }
    
    get_drivers = function(num_drivers){
      drivers = wrangler:children()
      rand_start = random:integer(drivers.length() - num_drivers).klog("random was")
      drivers.length() < num_drivers => drivers | 
        drivers.slice(rand_start, rand_start + (num_drivers - 1))
    }
    
    get_peers = function(self_name) {
      peers = wrangler:children()
      filtered = peers.filter(function(child){
        child{"name"} != self_name
      })
      rand_start = random:integer(filtered.length() - initial_peers).klog("random was")
      filtered.length() < initial_peers => filtered | 
        filtered.slice(rand_start, rand_start + (initial_peers - 1))
    }
    
    driver_exists = function(driver_name){
      drivers = wrangler:children(driver_name)
      drivers.isnull() && drivers.length() > 0
    }
    
    driver_rulesets = ["driver", "driver_profile", "driver_gossip"]
    initial_peers = 2
  }
  
  
  rule new_driver {
    select when flower_delivery new_driver
    pre{
      driver_name = event:attr("Driver Name")
      driver_location = event:attr("location")
    }
    if driver_name.isnull() || driver_name == "" || driver_exists(driver_name) then 
      send_directive("flower_delivery", {"new_driver": "Driver by the name of '" 
                                  + driver_name 
                                  + "' already exists or cannot be created!"})
    notfired {
      ent:pre_init_drivers{driver_name} := {"location": driver_location}
      raise wrangler event "child_creation"
      attributes {"name": driver_name,
                  "color": "#ffff00",
                  "rids": driver_rulesets }
    }
  }
  
  rule set_new_child_peers {
    select when wrangler child_initialized
    pre {
      driver_name = event:attr("name")
      eci = event:attr("eci")
    }
    always {
      raise flower_delivery event "need_peers"
        attributes {"name": driver_name,
                    "eci": eci}
    }
  }
  
  rule child_needs_driver_peers {
    select when flower_delivery need_peers
    pre {
      driver_name = event:attr("name")
      eci = event:attr("eci")
      peers = get_peers(driver_name)
    }
    if peers.isnull() == false && peers.length() > 0 then
      event:send({"eci":eci, 
                  "domain":"driver", 
                  "type":"initial_peers", 
                  "attrs":{"num_peers": peers.length(), 
                            "peers": peers}})
  }
  
  rule update_child_profile {
    select when wrangler child_initialized
    pre {
      driver_name = event:attr("name")
      eci = event:attr("eci")
    }
    if ent:pre_init_drivers >< driver_name then
      event:send({"eci":eci, 
                  "domain":"driver", 
                  "type":"profile_updated", 
                  "attrs":{"name": driver_name,
                           "location": ent:pre_init_drivers{driver_name}{"location"}}})
    fired {
      ent:pre_init_drivers := ent:pre_init_drivers.delete(driver_name)
    }
  }
  
  rule remove_driver {
    select when flower_delivery remove_driver
    pre {
      driver_name = event:attr("Driver Name")
    }
    if driver_exists(driver_name) then 
      send_directive("flower_delivery", {"destroy" : "The driver does not exist! Could not remove."})
    notfired {
      raise wrangler event "child_deletion"
        attributes {"name": driver_name};
    }
  }
  
  rule clear_drivers {
    select when flower_delivery remove_all_drivers
    foreach wrangler:children() setting(child)
    always{
      raise flower_delivery event "remove_driver"
        attributes {"Driver Name": child{"name"}}
    }
  }
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:pre_init_drivers := {}
    }
  }
  
  rule auto_accept {
    select when wrangler inbound_pending_subscription_added
    always {
      raise wrangler event "pending_subscription_approval" 
        attributes event:attrs;
    }
  }
}
