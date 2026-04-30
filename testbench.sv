//==============================================================================
// testbench.sv  -  UVM testbench for sync_fifo
//
// Beginner-friendly single-file UVM environment.
//
//   tb_top --+-- DUT (sync_fifo)
//            |
//            +-- fifo_if (interface)
//                   |
//   uvm_test --> env --+-- agent --+-- sequencer
//                      |           +-- driver
//                      |           +-- monitor --> analysis port
//                      |
//                      +-- scoreboard (queue-based reference model)
//
// One test runs three back-to-back scenarios:
//   1) RANDOM        - constrained-random writes/reads
//   2) FILL boundary - back-to-back writes, FIFO goes FULL
//   3) DRAIN boundary- back-to-back reads, FIFO goes EMPTY
//==============================================================================

`include "uvm_macros.svh"
import uvm_pkg::*;

//------------------------------------------------------------------------------
// Interface  -  the "wires" between DUT and TB
//------------------------------------------------------------------------------
interface fifo_if (input logic clk, input logic rst_n);
    logic       wr_en;
    logic [7:0] wr_data;
    logic       rd_en;
    logic [7:0] rd_data;
    logic       full;
    logic       empty;
endinterface


//------------------------------------------------------------------------------
// Transaction  -  one atomic stimulus (one cycle of wr/rd activity)
//------------------------------------------------------------------------------
class fifo_txn extends uvm_sequence_item;

    rand bit       wr_en;
    rand bit       rd_en;
    rand bit [7:0] wr_data;

    // Sampled by the monitor
    bit [7:0] rd_data;
    bit       full;
    bit       empty;

    // Default: lean toward activity, allow simultaneous read+write
    constraint c_default {
        wr_en dist {1 := 60, 0 := 40};
        rd_en dist {1 := 60, 0 := 40};
    }

    `uvm_object_utils_begin(fifo_txn)
        `uvm_field_int(wr_en,   UVM_ALL_ON)
        `uvm_field_int(rd_en,   UVM_ALL_ON)
        `uvm_field_int(wr_data, UVM_ALL_ON)
        `uvm_field_int(rd_data, UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_int(full,    UVM_ALL_ON | UVM_NOCOMPARE)
        `uvm_field_int(empty,   UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_object_utils_end

    function new(string name = "fifo_txn");
        super.new(name);
    endfunction
endclass


//------------------------------------------------------------------------------
// Driver  -  drives interface signals based on transactions
//------------------------------------------------------------------------------
class fifo_driver extends uvm_driver #(fifo_txn);
    `uvm_component_utils(fifo_driver)

    virtual fifo_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db#(virtual fifo_if)::get(this, "", "vif", vif))
            `uvm_fatal("DRV", "Could not get virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
        vif.wr_en   <= 0;
        vif.rd_en   <= 0;
        vif.wr_data <= 0;
        @(posedge vif.rst_n);

        forever begin
            fifo_txn t;
            seq_item_port.get_next_item(t);
            @(posedge vif.clk);
            vif.wr_en   <= t.wr_en;
            vif.rd_en   <= t.rd_en;
            vif.wr_data <= t.wr_data;
            @(posedge vif.clk);
            vif.wr_en   <= 0;
            vif.rd_en   <= 0;
            seq_item_port.item_done();
        end
    endtask
endclass


//------------------------------------------------------------------------------
// Monitor  -  samples the bus and forwards to the scoreboard
//------------------------------------------------------------------------------
class fifo_monitor extends uvm_monitor;
    `uvm_component_utils(fifo_monitor)

    virtual fifo_if               vif;
    uvm_analysis_port #(fifo_txn) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        if (!uvm_config_db#(virtual fifo_if)::get(this, "", "vif", vif))
            `uvm_fatal("MON", "Could not get virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
        @(posedge vif.rst_n);
        forever begin
            @(posedge vif.clk);
            #1; // settle so we read post-NBA values cleanly
            if (vif.wr_en || vif.rd_en) begin
                fifo_txn t = fifo_txn::type_id::create("t");
                t.wr_en   = vif.wr_en;
                t.rd_en   = vif.rd_en;
                t.wr_data = vif.wr_data;
                t.rd_data = vif.rd_data;
                t.full    = vif.full;
                t.empty   = vif.empty;
                ap.write(t);
            end
        end
    endtask
endclass


//------------------------------------------------------------------------------
// Agent  -  bundles sequencer + driver + monitor
//------------------------------------------------------------------------------
class fifo_agent extends uvm_agent;
    `uvm_component_utils(fifo_agent)

    uvm_sequencer #(fifo_txn) sqr;
    fifo_driver               drv;
    fifo_monitor              mon;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        sqr = uvm_sequencer#(fifo_txn)::type_id::create("sqr", this);
        drv = fifo_driver           ::type_id::create("drv", this);
        mon = fifo_monitor          ::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass


//------------------------------------------------------------------------------
// Scoreboard  -  reference model is a SystemVerilog queue
//------------------------------------------------------------------------------
class fifo_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(fifo_scoreboard)

    uvm_analysis_imp #(fifo_txn, fifo_scoreboard) ap_imp;

    bit [7:0] ref_q [$];      // golden FIFO
    int writes, reads, errors;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap_imp = new("ap_imp", this);
    endfunction

    // Called by monitor.ap.write()
    function void write(fifo_txn t);
        // ----- Accepted write? -----
        if (t.wr_en && !t.full) begin
            ref_q.push_back(t.wr_data);
            writes++;
            `uvm_info("SB", $sformatf("WRITE 0x%02h  (depth=%0d)",
                                       t.wr_data, ref_q.size()), UVM_MEDIUM)
        end
        else if (t.wr_en && t.full) begin
            `uvm_info("SB", "WRITE attempted while FULL  -> dropped (correct)",
                      UVM_MEDIUM)
        end

        // ----- Accepted read? -----
        if (t.rd_en && !t.empty) begin
            bit [7:0] expected;
            if (ref_q.size() == 0) begin
                errors++;
                `uvm_error("SB", "Read accepted but reference is empty!")
            end else begin
                expected = ref_q.pop_front();
                if (expected !== t.rd_data) begin
                    errors++;
                    `uvm_error("SB", $sformatf("MISMATCH: exp=0x%02h got=0x%02h",
                                                expected, t.rd_data))
                end else begin
                    reads++;
                    `uvm_info("SB", $sformatf("READ  0x%02h  MATCH (depth=%0d)",
                                               t.rd_data, ref_q.size()), UVM_MEDIUM)
                end
            end
        end
        else if (t.rd_en && t.empty) begin
            `uvm_info("SB", "READ attempted while EMPTY -> dropped (correct)",
                      UVM_MEDIUM)
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SB", "===== Scoreboard summary =====", UVM_LOW)
        `uvm_info("SB", $sformatf("  writes = %0d", writes),       UVM_LOW)
        `uvm_info("SB", $sformatf("  reads  = %0d", reads),        UVM_LOW)
        `uvm_info("SB", $sformatf("  errors = %0d", errors),       UVM_LOW)
        `uvm_info("SB", $sformatf("  residue in ref = %0d",
                                   ref_q.size()), UVM_LOW)
        if (errors == 0) `uvm_info("SB", "*** TEST PASSED ***", UVM_LOW)
        else             `uvm_error("SB", "*** TEST FAILED ***")
    endfunction
endclass


//------------------------------------------------------------------------------
// Environment  -  agent + scoreboard
//------------------------------------------------------------------------------
class fifo_env extends uvm_env;
    `uvm_component_utils(fifo_env)

    fifo_agent      agt;
    fifo_scoreboard sb;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        agt = fifo_agent     ::type_id::create("agt", this);
        sb  = fifo_scoreboard::type_id::create("sb",  this);
    endfunction

    function void connect_phase(uvm_phase phase);
        agt.mon.ap.connect(sb.ap_imp);
    endfunction
endclass


//==============================================================================
// SEQUENCES
//==============================================================================

// 1. Constrained-random read/write traffic
class random_seq extends uvm_sequence #(fifo_txn);
    `uvm_object_utils(random_seq)
    function new(string name = "random_seq"); super.new(name); endfunction

    task body();
        repeat (40) begin
            `uvm_do(req)
        end
    endtask
endclass

// 2. Boundary: keep writing -> hit FULL
class fill_seq extends uvm_sequence #(fifo_txn);
    `uvm_object_utils(fill_seq)
    function new(string name = "fill_seq"); super.new(name); endfunction

    task body();
        // DEPTH is 8, send more so we exercise dropped-on-full
        repeat (12) begin
            `uvm_do_with(req, { wr_en == 1; rd_en == 0; })
        end
    endtask
endclass

// 3. Boundary: keep reading -> hit EMPTY
class drain_seq extends uvm_sequence #(fifo_txn);
    `uvm_object_utils(drain_seq)
    function new(string name = "drain_seq"); super.new(name); endfunction

    task body();
        // Read more than DEPTH so we exercise dropped-on-empty
        repeat (12) begin
            `uvm_do_with(req, { wr_en == 0; rd_en == 1; })
        end
    endtask
endclass


//==============================================================================
// TEST  -  runs all three sequences back to back
//==============================================================================
class fifo_test extends uvm_test;
    `uvm_component_utils(fifo_test)

    fifo_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        env = fifo_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
        random_seq rseq;
        fill_seq   fseq;
        drain_seq  dseq;

        phase.raise_objection(this);

        `uvm_info("TEST", "===== 1/3  CONSTRAINED-RANDOM TRAFFIC =====", UVM_LOW)
        rseq = random_seq::type_id::create("rseq");
        rseq.start(env.agt.sqr);

        `uvm_info("TEST", "===== 2/3  BOUNDARY: FILL TO FULL =====", UVM_LOW)
        fseq = fill_seq::type_id::create("fseq");
        fseq.start(env.agt.sqr);

        `uvm_info("TEST", "===== 3/3  BOUNDARY: DRAIN TO EMPTY =====", UVM_LOW)
        dseq = drain_seq::type_id::create("dseq");
        dseq.start(env.agt.sqr);

        #100;
        phase.drop_objection(this);
    endtask
endclass


//==============================================================================
// TOP MODULE  -  clock, reset, DUT, run_test
//==============================================================================
module tb_top;

    bit clk;
    bit rst_n;

    // 100 MHz clock
    initial clk = 0;
    always #5 clk = ~clk;

    // Reset
    initial begin
        rst_n = 0;
        #23 rst_n = 1;
    end

    // Interface + DUT
    fifo_if vif (clk, rst_n);

    sync_fifo #(.DATA_WIDTH(8), .DEPTH(8)) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .wr_en  (vif.wr_en),
        .wr_data(vif.wr_data),
        .rd_en  (vif.rd_en),
        .rd_data(vif.rd_data),
        .full   (vif.full),
        .empty  (vif.empty)
    );

    // Hand the interface to the UVM env, then start the test
    initial begin
        uvm_config_db#(virtual fifo_if)::set(null, "*", "vif", vif);
        run_test("fifo_test");
    end

    // Waveform dump for EDA Playground EPWave
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
