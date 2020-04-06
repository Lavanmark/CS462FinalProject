ruleset driver_manager {
  meta {
    use module io.picolabs.wrangler alias wrangler
    shares __testing, get_drivers
    provides get_drivers
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_drivers", "attrs" : ["num_drivers"] }
      ] , "events":
      [ 
      ]
    }
    
    get_drivers = function(num_drivers){
      drivers = wrangler:children()
      rand_start = random:integer(drivers.length() - num_drivers).klog("random was")
      drivers.length() < num_drivers => drivers | 
        drivers.slice(rand_start, rand_start + (num_drivers - 1))
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
