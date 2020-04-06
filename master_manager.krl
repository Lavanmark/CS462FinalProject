ruleset master_manager {
  meta {
    use module io.picolabs.wrangler alias wrangler
    shares __testing, flower_delivery_exists
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "flower_delivery_exists"}
      ] , "events":
      [ { "domain": "flower_delivery", "type": "initialize" },
        { "domain": "flower_delivery", "type": "destroy" }
      ]
    }
    
    flower_delivery_exists = function(){
      wrangler:children().any(function(child){ 
                child{"name"} == shop_manager || child{"name"} == driver_manager
              })
    }
    
    shop_manager = "Shop Manager"
    driver_manager = "Driver Manager"
    shop_rulesets = ["flower_shop_manager"]
    driver_rulesets = ["driver_manager"]
  }
  
  
  rule initialize {
    select when flower_delivery initialize
    pre{
      exists = flower_delivery_exists()
    }
    if exists then 
      send_directive("flower_delivery", {"initialize": "Shop Manager and Driver Manager already exist!"})
    notfired {
      raise wrangler event "child_creation"
      attributes {"name": shop_manager,
                  "color": "#ffff00",
                  "rids": shop_rulesets }
      raise wrangler event "child_creation"
      attributes {"name": driver_manager,
                  "color": "#ffff00",
                  "rids": driver_rulesets }
    }
  }
  
  rule subscribe_shops_to_drivers {
    select when wrangler child_initialized name re#Shop Manager# //setting(shop_name)
            and wrangler child_initialized name re#Driver Manager# //setting(driver_name)
    pre {
      sm_child = wrangler:children(shop_manager).head().klog("Shop Manager Info:")
      dm_child = wrangler:children(driver_manager).head().klog("Driver Manager Info:")
      sm_rx = wrangler:skyQuery(sm_child{"eci"}, "io.picolabs.subscription", "wellKnown_Rx")["id"]
      dm_rx = wrangler:skyQuery(dm_child{"eci"}, "io.picolabs.subscription", "wellKnown_Rx")["id"]
    }
      event:send({"eci":sm_rx, "domain":"wrangler", "type":"subscription", "attrs":{
        "name" : "Shop Manager to Driver Manager",
        "Rx_role": "shop_manager",
        "Tx_role": "driver_manager",
        "channel_type": "subscription",
        "wellKnown_Tx" : dm_rx
      }})
  }
  
  
  rule remove_managers {
    select when flower_delivery destroy
    if flower_delivery_exists() == false then 
      send_directive("flower_delivery", {"destroy" : "The shop manager or driver manager do not exist! Could not destroy."})
    notfired{
      raise wrangler event "child_deletion"
        attributes {"name": shop_manager};
      raise wrangler event "child_deletion"
        attributes {"name": driver_manager};
    }
  }
}
