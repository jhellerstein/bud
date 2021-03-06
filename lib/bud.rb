require 'rubygems'
require 'eventmachine'
require 'msgpack'
require 'socket'
require 'superators'
require 'thread'

require 'bud/monkeypatch'

require 'bud/aggs'
require 'bud/bud_meta'
require 'bud/collections'
require 'bud/depanalysis'
require 'bud/deploy/forkdeploy'
require 'bud/deploy/threaddeploy'
require 'bud/errors'
require 'bud/joins'
require 'bud/metrics'
require 'bud/rtrace'
require 'bud/server'
require 'bud/state'
require 'bud/storage/dbm'
require 'bud/storage/tokyocabinet'
require 'bud/storage/zookeeper'
require 'bud/stratify'
require 'bud/viz'

require 'bud/executor/elements.rb'
require 'bud/executor/group.rb'
require 'bud/executor/join.rb'

ILLEGAL_INSTANCE_ID = -1
SIGNAL_CHECK_PERIOD = 0.2

$signal_lock = Mutex.new
$got_shutdown_signal = false
$signal_handler_setup = false
$instance_id = 0
$bud_instances = {}        # Map from instance id => Bud instance

# The root Bud module. To cause an instance of Bud to begin executing, there are
# three main options:
#
# 1. Synchronously. To do this, instantiate your program and then call tick()
#    one or more times; each call evaluates a single Bud timestep. Note that in
#    this mode, network communication (channels) and timers cannot be used. This
#    is mostly intended for "one-shot" programs that compute a single result and
#    then terminate.
# 2. In a separate thread in the foreground. To do this, instantiate your
#    program and then call run_fg(). The Bud interpreter will then run, handling
#    network events and evaluating new timesteps as appropriate. The run_fg()
#    method will not return unless an error occurs.
# 3. In a separate thread in the background. To do this, instantiate your
#    program and then call run_bg(). The Bud interpreter will run
#    asynchronously. To interact with Bud (e.g., insert additional data or
#    inspect the state of a Bud collection), use the sync_do and async_do
#    methods. To shutdown the Bud interpreter, use stop_bg().
#
# Most programs should use method #3.
#
# :main: Bud
module Bud
  attr_reader :strata, :budtime, :inbound, :options, :meta_parser, :viz, :rtracer
  attr_reader :dsock
  attr_reader :tables, :channels, :tc_tables, :zk_tables, :dbm_tables, :sources, :sinks
  attr_reader :push_sources, :push_elems, :push_joins, :scanners, :delta_scanners, :merge_targets, :done_wiring
  attr_reader :stratum_first_iter, :joinstate
  attr_reader :this_stratum, :this_rule, :rule_orig_src, :done_bootstrap, :done_wiring
  attr_accessor :lazy # This can be changed on-the-fly by REBL
  attr_accessor :stratum_collection_map, :rewritten_strata, :no_attr_rewrite_strata
  attr_accessor :metrics

  # options to the Bud runtime are passed in a hash, with the following keys
  # * network configuration
  #   * <tt>:ip</tt>   IP address string for this instance
  #   * <tt>:port</tt>   port number for this instance
  #   * <tt>:ext_ip</tt>  IP address at which external nodes can contact this instance
  #   * <tt>:ext_port</tt>   port number to go with <tt>:ext_ip</tt>
  #   * <tt>:bust_port</tt>  port number for the restful HTTP messages
  # * operating system interaction
  #   * <tt>:stdin</tt>  if non-nil, reading from the +stdio+ collection results in reading from this +IO+ handle
  #   * <tt>:stdout</tt> writing to the +stdio+ collection results in writing to this +IO+ handle; defaults to <tt>$stdout</tt>
  #   * <tt>:no_signal_handlers</tt> if true, runtime ignores +SIGINT+ and +SIGTERM+
  # * tracing and output
  #   * <tt>:quiet</tt> if true, suppress certain messages
  #   * <tt>:trace</tt> if true, generate +budvis+ outputs
  #   * <tt>:rtrace</tt>  if true, generate +budplot+ outputs
  #   * <tt>:dump_rewrite</tt> if true, dump results of internal rewriting of Bloom code to a file
  #   * <tt>:print_wiring</tt> if true, print the wiring diagram of the program to stdout
  #   * <tt>:metrics</tt> if true, dumps a hash of internal performance metrics
  # * controlling execution
  #   * <tt>:lazy</tt>  if true, prevents runtime from ticking except on external calls to +tick+
  #   * <tt>:tag</tt>  a name for this instance, suitable for display during tracing and visualization
  # * storage configuration
  #   * <tt>:dbm_dir</tt> filesystem directory to hold DBM-backed collections
  #   * <tt>:dbm_truncate</tt> if true, DBM-backed collections are opened with +OTRUNC+
  #   * <tt>:tc_dir</tt>  filesystem directory to hold TokyoCabinet-backed collections
  #   * <tt>:tc_truncate</tt> if true, TokyoCabinet-backed collections are opened with +OTRUNC+
  # * deployment
  #   * <tt>:deploy</tt>  enable deployment
  #   * <tt>:deploy_child_opts</tt> option hash to pass to deployed instances
  def initialize(options={})
    @tables = {}
    @table_meta = []
    @rewritten_strata = []
    @channels = {}
    @push_elems = {}
    @tc_tables = {}
    @dbm_tables = {}
    @zk_tables = {}
    @callbacks = {}
    @callback_id = 0
    @shutdown_callbacks = []
    @post_shutdown_callbacks = []
    @timers = []
    @inside_tick = false
    @tick_clock_time = nil
    @budtime = 0
    @inbound = []
    @done_bootstrap = false
    @done_wiring = false
    @joinstate = {}  # joins are stateful, their state needs to be kept inside the Bud instance
    @instance_id = ILLEGAL_INSTANCE_ID # Assigned when we start running
    @sources = {}
    @sinks = {}
    @metrics = {}
    @endtime = nil
    
    # XXX This variable is unused in the Push executor
    @stratum_first_iter = false

    # Setup options (named arguments), along with default values
    @options = options.clone
    @lazy = @options[:lazy] ||= false
    @options[:ip] ||= "127.0.0.1"
    @ip = @options[:ip]
    @options[:port] ||= 0
    @options[:port] = @options[:port].to_i
    # NB: If using an ephemeral port (specified by port = 0), the actual port
    # number won't be known until we start EM

    relatives = self.class.modules + [self.class]
    relatives.each do |r|
      Bud.rewrite_local_methods(r)
    end

    @declarations = ModuleRewriter.get_rule_defs(self.class)

    init_state

    @viz = VizOnline.new(self) if @options[:trace]
    @rtracer = RTrace.new(self) if @options[:rtrace]

    # Get dependency info and determine stratification order.
    unless self.class <= Stratification or self.class <= DepAnalysis
      do_rewrite
    end

    # Load the rules as a closure. Each element of @strata is an array of
    # lambdas, one for each rewritten rule in that stratum. Note that legacy Bud
    # code (with user-specified stratification) assumes that @strata is a simple
    # array, so we need to convert it before loading the rewritten strata.
    @strata = []
    @rule_src = []
    @rule_orig_src = []
    declaration
    @strata.each_with_index do |s,i|
      raise BudError if s.class <= Array
      @strata[i] = [s]
      # Don't try to record source text for old-style rule blocks
      @rule_src[i] = [""]
    end

    @rewritten_strata.each_with_index do |src_ary,i|
      @strata[i] ||= []
      @rule_src[i] ||= []
      @rule_orig_src[i] ||= []
      src_ary.each_with_index do |src, j|
        @strata[i] << eval("lambda { #{src} }")
        @rule_src[i] << src
        @rule_orig_src[i] << @no_attr_rewrite_strata[i][j]
      end
    end
    # now that we know how many strata there are, initialize per-stratum state
    @scanners = @strata.length.times.map{{}}
    @delta_scanners = @strata.length.times.map{{}}
    @push_sources = @strata.length.times.map{{}}
    @push_joins = @strata.length.times.map{[]}
    @merge_targets = @strata.length.times.map{{}}

    # do_wiring
  end

  private

  # Rewrite methods defined in the given klass to expand module references and
  # temp collections. Imported modules are rewritten during the import process;
  # we rewrite the main Bud class and any included modules here. Note that we
  # only rewrite each distinct Class once.
  def self.rewrite_local_methods(klass)
    @done_rewrite ||= {}
    return if @done_rewrite.has_key? klass.name

    u = Unifier.new
    ref_expander = NestedRefRewriter.new(klass.bud_import_table)
    tmp_expander = TempExpander.new
    r2r = Ruby2Ruby.new

    klass.instance_methods(false).each do |m|
      ast = ParseTree.translate(klass, m)
      ast = u.process(ast)
      ast = ref_expander.process(ast)
      ast = tmp_expander.process(ast)

      if (ref_expander.did_work or tmp_expander.did_work)
        new_source = r2r.process(ast)
        klass.module_eval new_source # Replace previous method def
      end

      ref_expander.did_work = false
      tmp_expander.did_work = false
    end

    # If we found any temp statements in the klass's rule blocks, add a state
    # block with declarations for the corresponding temp collections.
    s = tmp_expander.get_state_meth(klass)
    if s
      state_src = r2r.process(s)
      klass.module_eval(state_src)
    end

    # Always rewrite anonymous classes
    @done_rewrite[klass.name] = true unless klass.name == ""
  end

  # Invoke all the user-defined state blocks and initialize builtin state.
  def init_state
    builtin_state
    call_state_methods
  end

  # If module Y is a parent module of X, X's state block might reference state
  # defined in Y. Hence, we want to invoke Y's state block first.  However, when
  # "import" and "include" are combined, we can't use the inheritance hierarchy
  # to do this. When a module Z is imported, the import process inlines all the
  # modules Z includes into a single module. Hence, we can no longer rely on the
  # inheritance hierarchy to respect dependencies between modules. To fix this,
  # we add an increasing ID to each state block's method name (assigned
  # according to the order in which the state blocks are defined); we then sort
  # by this order before invoking the state blocks.
  def call_state_methods
    meth_map = {} # map from ID => [Method]
    self.class.instance_methods.each do |m|
      next unless m =~ /^__state(\d+)__/
      id = Regexp.last_match.captures.first.to_i
      meth_map[id] ||= []
      meth_map[id] << self.method(m)
    end

    meth_map.keys.sort.each do |i|
      meth_map[i].each {|m| m.call}
    end
  end

  # Evaluate all bootstrap blocks and tick deltas
  def do_bootstrap
    self.class.ancestors.reverse.each do |anc|
      anc.instance_methods(false).each do |m|
        if /^__bootstrap__/.match m
          self.method(m.to_sym).call
        end
      end
    end
    bootstrap

    tables.each_value{|t| t.tick_deltas; t.tick_deltas}
    @done_bootstrap = true
  end
  
  def do_wiring
    @strata.each_with_index { |s,i| eval_rules(s, i) }
    @done_wiring = true
    if @options[:print_wiring]
      @push_sources.each do |strat| 
        strat.each_value{|src| src.print_wiring}
      end
    end
  end

  def do_rewrite
    @meta_parser = BudMeta.new(self, @declarations)
    @rewritten_strata, @no_attr_rewrite_strata = @meta_parser.meta_rewrite
  end

  public

  ########### give empty defaults for these
  def declaration # :nodoc: all
  end
  def bootstrap # :nodoc: all
  end

  ########### metaprogramming support for ruby and for rule rewriting
  # helper to define instance methods
  def singleton_class # :nodoc: all
    class << self; self; end
  end

  ######## methods for controlling execution

  # Run Bud in the background (in a different thread). This means that the Bud
  # interpreter will run asynchronously from the caller, so care must be used
  # when interacting with it. For example, it is not safe to directly examine
  # Bud collections from the caller's thread (see async_do and sync_do).
  #
  # This instance of Bud will continue to execute until stop_bg is called.
  def run_bg
    start_reactor
    # Wait for Bud to start up before returning
    schedule_and_wait do
      start_bud
    end
  end

  # Run Bud in the "foreground" -- the caller's thread will be used to run the
  # Bud interpreter. This means this method won't return unless an error
  # occurs. It is often more useful to run Bud asynchronously -- see run_bg.
  def run_fg
    # If we're called from the EventMachine thread (and EM is running), blocking
    # the current thread would imply deadlocking ourselves.
    if Thread.current == EventMachine::reactor_thread and EventMachine::reactor_running?
      raise BudError, "Cannot invoke run_fg from inside EventMachine"
    end

    q = Queue.new
    # Note that this must be a post-shutdown callback: if this is the only
    # thread, then the program might exit after run_fg() returns. If run_fg()
    # blocked on a normal shutdown callback, the program might exit before the
    # other shutdown callbacks have a chance to run.
    post_shutdown do
      q.push(true)
    end

    run_bg
    # Block caller's thread until Bud has shutdown
    q.pop
    report_metrics if options[:metrics]
  end

  # Shutdown a Bud instance that is running asynchronously. This method blocks
  # until Bud has been shutdown. If +stop_em+ is true, the EventMachine event
  # loop is also shutdown; this will interfere with the execution of any other
  # Bud instances in the same process (as well as anything else that happens to
  # use EventMachine).
  def stop_bg(stop_em=false, do_shutdown_cb=true)
    schedule_and_wait do
      do_shutdown(do_shutdown_cb)
    end

    if stop_em
      Bud.stop_em_loop
      EventMachine::reactor_thread.join
    end
    report_metrics if options[:metrics]
  end
  
  # Register a callback that will be invoked when this instance of Bud is
  # shutting down.
  def on_shutdown(&blk)
    # Start EM if not yet started
    start_reactor
    schedule_and_wait do
      @shutdown_callbacks << blk
    end
  end

  # Register a callback that will be invoked when *after* this instance of Bud
  # has been shutdown.
  def post_shutdown(&blk)
    # Start EM if not yet started
    start_reactor
    schedule_and_wait do
      @post_shutdown_callbacks << blk
    end
  end

  # Given a block, evaluate that block inside the background Ruby thread at some
  # time in the future. Because the block is evaluate inside the background Ruby
  # thread, the block can safely examine Bud state. Naturally, this method can
  # only be used when Bud is running in the background. Note that calling
  # sync_do blocks the caller until the block has been evaluated; for a
  # non-blocking version, see async_do.
  #
  # Note that the block is invoked after one Bud timestep has ended but before
  # the next timestep begins. Hence, synchronous accumulation (<=) into a Bud
  # scratch collection in a callback is typically not a useful thing to do: when
  # the next tick begins, the content of any scratch collections will be
  # emptied, which includes anything inserted by a sync_do block using <=. To
  # avoid this behavior, insert into scratches using <+.
  def sync_do
    schedule_and_wait do
      yield if block_given?
      # Do another tick, in case the user-supplied block inserted any data
      tick
    end
  end

  # Like sync_do, but does not block the caller's thread: the given callback
  # will be invoked at some future time. Note that calls to async_do respect
  # FIFO order.
  def async_do
    EventMachine::schedule do
      yield if block_given?
      # Do another tick, in case the user-supplied block inserted any data
      tick
    end
  end

  # Shutdown any persistent tables used by the current Bud instance. If you are
  # running Bud via tick() and using +tctable+ collections, you should call this
  # after you're finished using Bud. Programs that use Bud via run_fg() or
  # run_bg() don't need to call this manually.
  def close_tables
    @tables.each_value do |t|
      t.close
    end
  end

  # Register a new callback. Given the name of a Bud collection, this method
  # arranges for the given block to be invoked at the end of any tick in which
  # any tuples have been inserted into the specified collection. The code block
  # is passed the collection as an argument; this provides a convenient way to
  # examine the tuples inserted during that fixpoint. (Note that because the Bud
  # runtime is blocked while the callback is invoked, it can also examine any
  # other Bud state freely.)
  #
  # Note that registering callbacks on persistent collections (e.g., tables and
  # tctables) is probably not a wise thing to do: as long as any tuples are
  # stored in the collection, the callback will be invoked at the end of every
  # tick.
  def register_callback(tbl_name, &block)
    # We allow callbacks to be added before or after EM has been started. To
    # simplify matters, we start EM if it hasn't been started yet.
    start_reactor
    cb_id = nil
    schedule_and_wait do
      unless @tables.has_key? tbl_name
        raise Bud::BudError, "No such table: #{tbl_name}"
      end

      raise Bud::BudError if @callbacks.has_key? @callback_id
      @callbacks[@callback_id] = [tbl_name, block]
      cb_id = @callback_id
      @callback_id += 1
    end
    return cb_id
  end

  # Unregister the callback that has the given ID.
  def unregister_callback(id)
    schedule_and_wait do
      raise Bud::BudError unless @callbacks.has_key? id
      @callbacks.delete(id)
    end
  end

  # sync_callback supports synchronous interaction with Bud modules.  The caller
  # supplies the name of an input collection, a set of tuples to insert, and an
  # output collection on which to 'listen.'  The call blocks until tuples are
  # inserted into the output collection: these are returned to the caller.
  def sync_callback(in_tbl, tupleset, out_tbl)
    q = Queue.new
    cb = register_callback(out_tbl) do |c|
      q.push c.to_a
    end
    unless in_tbl.nil?
      sync_do {
        t = @tables[in_tbl]
        if t.class <= Bud::BudChannel or t.class <= Bud::BudZkTable
          t <~ tupleset
        else
          t <+ tupleset
        end
      }
    end
    result = q.pop
    unregister_callback(cb)
    return result
  end

  # A common special case for sync_callback: block on a delta to a table.
  def delta(out_tbl)
    sync_callback(nil, nil, out_tbl)
  end

  private

  def invoke_callbacks
    @callbacks.each_value do |cb|
      tbl_name, block = cb
      tbl = @tables[tbl_name]
      unless tbl.empty?
        block.call(tbl)
      end
    end
  end

  def start_reactor
    return if EventMachine::reactor_running?

    EventMachine::error_handler do |e|
      # Only print a backtrace if a non-BudError is raised (this presumably
      # indicates an unexpected failure).
      if e.class <= BudError
        puts "#{e.class}: #{e}"
      else
        puts "Unexpected Bud error: #{e.inspect}"
        puts e.backtrace.join("\n")
      end
      Bud.shutdown_all_instances
      raise e
    end

    # Block until EM has successfully started up.
    q = Queue.new
    # This thread helps us avoid race conditions on the start and stop of
    # EventMachine's event loop.
    Thread.new do
      EventMachine.run do
        q.push(true)
      end
    end
    # Block waiting for EM's event loop to start up.
    q.pop
  end

  # Schedule a block to be evaluated by EventMachine in the future, and
  # block until this has happened.
  def schedule_and_wait
    # If EM isn't running, just run the user's block immediately
    # XXX: not clear that this is the right behavior
    unless EventMachine::reactor_running?
      yield
      return
    end

    q = Queue.new
    EventMachine::schedule do
      ret = false
      begin
        yield
      rescue Exception
        ret = $!
      end
      q.push(ret)
    end

    resp = q.pop
    raise resp if resp
  end

  def do_shutdown(do_shutdown_cb=true)
    # Silently ignore duplicate shutdown requests or attempts to shutdown an
    # instance that hasn't been started yet.
    return if @instance_id == ILLEGAL_INSTANCE_ID

    $signal_lock.synchronize {
      raise unless $bud_instances.has_key? @instance_id
      $bud_instances.delete @instance_id
      @instance_id = ILLEGAL_INSTANCE_ID
    }

    if do_shutdown_cb
      @shutdown_callbacks.each {|cb| cb.call}
    end
    @timers.each {|t| t.cancel}
    close_tables
    @dsock.close_connection if EventMachine::reactor_running?
    if do_shutdown_cb
      @post_shutdown_callbacks.each {|cb| cb.call}
    end
  end

  private
  def start_bud
    raise BudError unless EventMachine::reactor_thread?

    @instance_id = Bud.init_signal_handlers(self)
    do_start_server

    # Initialize periodics
    @periodics.each do |p|
      @periodics.tuple_accessors(p)      
      @timers << set_periodic_timer(p.pername, p.ident, p.period)
    end

    # Arrange for Bud to read from stdin if enabled. Note that we can't do this
    # earlier because we need to wait for EventMachine startup.
    @stdio.start_stdin_reader if @options[:stdin]
    @zk_tables.each_value {|t| t.start_watchers}

    # Compute a fixpoint; this will also invoke any bootstrap blocks.
    tick unless @lazy

    @rtracer.sleep if options[:rtrace]
  end

  def do_start_server
    @dsock = EventMachine::open_datagram_socket(@ip, @options[:port],
                                                BudServer, self)
    @port = Socket.unpack_sockaddr_in(@dsock.get_sockname)[0]
  end

  public

  # Returns the IP and port of the Bud instance as a string.  In addition to the
  # local IP and port, the user may define an external IP and/or port. The
  # external version of each is returned if available.  If not, the local
  # version is returned.  There are use cases for mixing and matching local and
  # external.  local_ip:external_port would be if you have local port
  # forwarding, and external_ip:local_port would be if you're in a DMZ, for
  # example.
  def ip_port
    raise BudError, "ip_port called before port defined" if port.nil?
    ip.to_s + ":" + port.to_s
  end
  
  def ip
    ip = options[:ext_ip] ? "#{@options[:ext_ip]}" : "#{@ip}"
  end
  
  def port
    return nil if @port.nil? and @options[:port] == 0 and not @options[:ext_port]
    return options[:ext_port] ? "#{@options[:ext_port]}" :
      (@port.nil? ? "#{@options[:port]}" : "#{@port}")
  end

  # Returns the internal IP and port.  See ip_port.
  def int_ip_port
    raise BudError, "int_ip_port called before port defined" if @port.nil? and @options[:port] == 0
    @port.nil? ? "#{@ip}:#{@options[:port]}" : "#{@ip}:#{@port}"
  end

  # Manually trigger one timestep of Bloom execution.
  def tick
    begin
      starttime = Time.now if options[:metrics] 
      if options[:metrics] and not @endtime.nil?
        @metrics[:betweentickstats] ||= initialize_stats
        @metrics[:betweentickstats] = running_stats(@metrics[:betweentickstats], starttime - @endtime)
      end
      @inside_tick = true
      
      @joinstate = {}

      unless @done_bootstrap
        do_bootstrap
      else
        (@tables.values+@push_elems.values).each do |t|
          t.tick
        end
      end
      do_wiring unless @done_wiring
      receive_inbound

      # compute fixpoint for each stratum in order
      @strata.each_with_index do |s,i|
        fixpoint = false
        first_iter = true
        until fixpoint
          # puts "stratum #{i} iteration"
          fixpoint = true
          if first_iter
            # push in the stored tuples from previous fixpoint
            @scanners[i].each_value {|s| s << [:go]}
          else
            # push in any deltas from last iteration
            delta_scanners[i].each_value{|d| d << [:go]} unless first_iter
          end
          # flush any tuples in the pipes
          push_sources[i].each_value {|p| p.flush}
          # tick deltas on any merge targets and look for more deltas
          merge_targets[i].each_key do |t| 
            fixpoint = false if t.tick_deltas
          end
          # check to see if any joins saw a delta
          push_joins[i].each do |p| 
            if p.found_delta==true
              fixpoint = false 
              p.tick_deltas
            end
          end
          first_iter = false
        end
        # push end-of-fixpoint
        push_sources[i].each_value{|p| p.end}
        merge_targets[i].each_key do |t| 
          t.flush_deltas
        end
        
      end
      
      @viz.do_cards if @options[:trace]
      do_flush
      invoke_callbacks
      @budtime += 1
      @inbound.clear
    ensure
      @inside_tick = false
      @tick_clock_time = nil
    end

    if options[:metrics]  
      @endtime = Time.now   
      @metrics[:tickstats] ||= initialize_stats
      @metrics[:tickstats] = running_stats(@metrics[:tickstats], @endtime - starttime)
    end
  end
  
  # Returns the wallclock time associated with the current Bud tick. That is,
  # this value is guaranteed to remain the same for the duration of a single
  # tick, but will likely change between ticks.
  def bud_clock
    raise BudError, "bud_clock undefined outside tick" unless @inside_tick
    @tick_clock_time ||= Time.now
    @tick_clock_time
  end

  private

  # Builtin BUD state (predefined collections). We could define this using the
  # standard "state" syntax, but we want to ensure that builtin state is
  # initialized before user-defined state.
  def builtin_state
    loopback  :localtick, [:col1]
    @stdio = terminal :stdio
    @periodics = table :periodics_tbl, [:pername] => [:ident, :period]

    # for BUD reflection
    table :t_rules, [:rule_id] => [:lhs, :op, :src, :orig_src]
    table :t_depends, [:rule_id, :lhs, :op, :body] => [:nm]
    table :t_depends_tc, [:head, :body, :via, :neg, :temporal]
    table :t_provides, [:interface] => [:input]
    table :t_underspecified, t_provides.schema
    table :t_stratum, [:predicate] => [:stratum]
    table :t_cycle, [:predicate, :via, :neg, :temporal]
    table :t_table_info, [:tab_name, :tab_type]
    table :t_table_schema, [:tab_name, :col_name, :ord, :loc]
  end

  # Handle any inbound tuples off the wire. Received messages are placed
  # directly into the storage of the appropriate local channel. The inbound
  # queue is cleared at the end of the tick.
  def receive_inbound
    @inbound.each do |msg|
      tables[msg[0].to_sym] << msg[1]
    end
  end

  # "Flush" any tuples that need to be flushed. This does two things:
  # 1. Emit outgoing tuples in channels and ZK tables.
  # 2. Commit to disk any changes made to on-disk tables.
  def do_flush
    @channels.each_value { |c| c.flush }
    @zk_tables.each_value { |t| t.flush }
    @tc_tables.each_value { |t| t.flush }
    @dbm_tables.each_value { |t| t.flush }
  end

  def eval_rules(strat, strat_num)
    # This routine evals the rules in a given stratum, which results in a wiring of PushElements
    @this_stratum = strat_num  
    strat.each_with_index do |r,i|
      @this_rule = i
      rule_src = @rule_orig_src[strat_num][i] unless @rule_orig_src[strat_num].nil?
      begin
        r.call
      rescue Exception => e
        # Don't report source text for certain rules (old-style rule blocks)
        src_msg = ""
        unless rule_src == ""
          src_msg = "\nRule: #{rule_src}"
        end
        new_e = e
        unless new_e.class <= BudError
          new_e = BudError
        end
        raise new_e, "Exception during Bud wiring.\nException: #{e.inspect}.#{src_msg}"
      end
    end
  end

  private

  ######## ids and timers
  def gen_id
    Time.new.to_i.to_s << rand.to_s
  end

  def set_periodic_timer(name, id, period)
    EventMachine::PeriodicTimer.new(period) do
      @tables[name].add_periodic_tuple(id)
      tick
    end
  end

  # Fork a new process. This is identical to Kernel#fork, except that it also
  # cleans up Bud and EventMachine-related state. As with Kernel#fork, the
  # caller supplies a code block that is run in the child process; the PID of
  # the child is returned by this method.
  def self.do_fork
    Kernel.fork do
      srand
      # This is somewhat grotty: we basically clone what EM::fork_reactor does,
      # except that we don't want the user-supplied block to be invoked by the
      # reactor thread.
      if EventMachine::reactor_running?
        EventMachine::stop_event_loop
        EventMachine::release_machine
        EventMachine::instance_variable_set('@reactor_running', false)
      end
      # Shutdown all the Bud instances inherited from the parent process, but
      # don't invoke their shutdown callbacks
      Bud.shutdown_all_instances(false)

      $got_shutdown_signal = false
      $setup_signal_handler = false

      yield
    end
  end

  # Note that this affects anyone else in the same process who happens to be
  # using EventMachine! This is also a non-blocking call; to block until EM
  # has completely shutdown, join on EM::reactor_thread.
  def self.stop_em_loop
    EventMachine::stop_event_loop

    # If another instance of Bud is started later, we'll need to reinitialize
    # the signal handlers (since they depend on EM).
    $signal_handler_setup = false
  end

  # Signal handling. If multiple Bud instances are running inside a single
  # process, we want a SIGINT or SIGTERM signal to cleanly shutdown all of them.
  def self.init_signal_handlers(b)
    $signal_lock.synchronize {
      # If we setup signal handlers and then fork a new process, we want to
      # reinitialize the signal handler in the child process.
      unless b.options[:no_signal_handlers] or $signal_handler_setup
        EventMachine::PeriodicTimer.new(SIGNAL_CHECK_PERIOD) do
          if $got_shutdown_signal
            Bud.shutdown_all_instances
            Bud.stop_em_loop
            $got_shutdown_signal = false
          end
        end

        ["INT", "TERM"].each do |signal|
          Signal.trap(signal) {
            $got_shutdown_signal = true
          }
        end
        $setup_signal_handler_pid = true
      end

      $instance_id += 1
      $bud_instances[$instance_id] = b
      return $instance_id
    }
  end

  def self.shutdown_all_instances(do_shutdown_cb=true)
    instances = nil
    $signal_lock.synchronize {
      instances = $bud_instances.clone
    }

    instances.each_value {|b| b.stop_bg(false, do_shutdown_cb) }
  end
end
