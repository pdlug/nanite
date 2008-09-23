require 'nanite/reducer'
require 'nanite/dispatcher'

module Nanite
  class Runner
    
    def self.start(opts={})
      EM.run{
        ping_time = opts.delete(:ping_time) || 30
        AMQP.start opts
        Mapper.new(ping_time)
      }  
    end
  end  
  
  class Mapper
    
    def log *args
      p args
    end
    
    def initialize(ping_time)
      @identity = Nanite.gen_token
      @ping_time = ping_time
      @nanites = {}
      @amq = MQ.new
      setup_queues
      EM.add_timer(@ping_time * 1.2) do
        log "starting mapper with nanites(#{@nanites.keys.size}):", @nanites.keys
        MQ.new.rpc('mapper', self) 
      end
      EM.add_periodic_timer(@ping_time) { check_pings }
    end
    
    def setup_queues
      @amq.queue("pings#{@identity}",:exclusive => true).bind(@amq.topic('heartbeat'), :key => 'nanite.pings').subscribe{ |ping|
        handle_ping(Marshal.load(ping))
      }
      @amq.queue("mapper#{@identity}",:exclusive => true).bind(@amq.topic('registration'), :key => 'nanite.register').subscribe{ |msg|
        register(Marshal.load(msg))
      }
    end        
    
    def handle_ping(ping)
      if nanite = @nanites[ping.from]
        nanite[:timestamp] = Time.now
        @amq.queue(ping.identity).publish(Marshal.dump(Nanite::Pong.new(ping)))
      else
        @amq.queue(ping.identity).publish(Marshal.dump(Nanite::Advertise.new(ping)))
      end  
    end
    
    def check_pings
      time = Time.now
      @nanites.each do |name, content|
        if (time - content[:timestamp]) > @ping_time
          @nanites.delete(name)
          log "removed #{name} from mapping/registration"
        end
      end  
    end
    
    def register(reg)
      @nanites[reg.name] = {:timestamp => Time.now,
                            :resources => reg.resources,
                            :identity  => reg.identity}
      log "registered:", reg.name, reg.identity, reg.resources
    end
        
    def discover(resources)
      log "discover:", resources
      names = []
      @nanites.each do |name, content|      
        names << [name, content[:identity]] if Nanite::Dispatcher.can_provide?(resources, content[:resources])
      end  
      names
    end
    
    def route(op)
      log "route(op) from:#{op.from}" 
      targets = discover(op.resources)
      token = Nanite.gen_token
      answer = Answer.new(token)
      op.token = token
      
      targets.reject! { |target| ! allowed?(op.from, target.first) }
      
      workers = targets.map{|t| t.first }  
      answer.workers = Hash[*workers.zip(Array.new(workers.size, :waiting)).flatten]
    
      EM.next_tick {
        targets.each do |target|
          send_op(op, target.last)
        end
      }
      answer
    end
    
    def file(getfile)
      log "file(getfile) from:#{getfile.from}" 
      target = discover(getfile.resources).first
      token = Nanite.gen_token
      file_transfer = FileTransfer.new(token)
      getfile.token = token
      
      if allowed?(getfile.from, target.first)       
        file_transfer.worker = target.first
        EM.next_tick {
          send_op(getfile, target.last)
        }
        file_transfer
      else
      end    
    end
    
    def send_op(op, target)
      log "send_op:", op, target
      @amq.queue(target).publish(Marshal.dump(op))
    end
        
    def allowed?(from, to)
      true
    end    
        
  end  
end