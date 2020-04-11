ruleset driver_profile {
  meta {
    use module io.picolabs.subscription alias subscription
    use module io.picolabs.wrangler alias wrangler
    shares __testing, get_rating, get_location, get_profile
    provides get_profile, get_rating
  }
  global {
    __testing = { "queries":
      [ { "name": "__testing" },
        { "name": "get_rating" },
        { "name": "get_location" },
        { "name": "get_profile" }
      ] , "events":
      [ 
        { "domain": "driver", "type": "update_rating", "attrs": ["rating"] },
        { "domain": "driver", "type": "location_updated", "attrs": ["location"] },
        { "domain": "driver", "type": "profile_updated", "attrs": ["name", "location"] }
      ]
    }
    
    get_rating = function() {
      ent:driver_rating
    }
    
    get_location = function() {
      ent:location
    }
    
    get_profile = function() {
      {
        "id": meta:picoId,
        "name": ent:name,
        "location": ent:location,
        "rating": ent:driver_rating,
        "contact_tx": wrangler:myself(){"eci"},
        "wellknown": subscription:wellKnown_Rx()["id"]
      }
    }
    
    calc_rating = function(rating) {
      old_sum = ent:driver_rating * ent:total_ratings
      new_sum = rating + old_sum
      new_total = ent:total_ratings + 1
      new_rating = new_sum / new_total
      new_rating
    }
    
  }
  
  rule update_rating {
    select when driver update_rating
    pre {
      rating = event:attr("rating").as("Number")
      new_rating = calc_rating(rating).as("Number")
    }
    always{
      ent:driver_rating := new_rating
      ent:total_ratings := ent:total_ratings + 1
    }
  }
  
  rule location_updated {
    select when driver location_updated
    pre {
      new_location = event:attr("location")
    }
    always {
      ent:location := new_location
    }
  }
  
  rule profile_updated {
    select when driver profile_updated
    pre {
      name = event:attr("name")
      loc = event:attr("location")
    }
    send_directive("driver", {"profile_updated": "Profile Updated!"})
    always {
      ent:name := name
      ent:location := loc
    }
  }
  
  
  rule ruleset_added { 
    //initialize all entity variables here
    select when wrangler ruleset_added where rids >< meta:rid
    always {
        ent:name := wrangler:myself(){"name"}
        ent:location := "Salt Lake City,UT"
        ent:driver_rating := 5
        ent:total_ratings := 0
    }
  }
}
