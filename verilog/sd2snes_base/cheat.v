`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date:    16:53:07 07/01/2014
// Design Name:
// Module Name:    cheat
// Project Name:
// Target Devices:
// Tool versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////
module cheat(
  input clk,
  input [7:0] SNES_PA,
  input [23:0] SNES_ADDR,
  input [7:0] SNES_DATA,
  input SNES_wr_strobe,
  input SNES_rd_strobe,
  input SNES_reset_strobe,
  input snescmd_enable,
  input nmicmd_enable,
  input return_vector_enable,
  input branch1_enable,
  input branch2_enable,
  input branch3_enable,
  input exe_present,
  input pad_latch,
  input snes_ajr,
  input SNES_cycle_start,
  input [2:0] pgm_idx,
  input pgm_we,
  input [31:0] pgm_in,
  input feat_cmd_unlock_in,
  output [7:0] data_out,
  output cheat_hit,
  output snescmd_unlock,
  output map_unlock
);

wire snescmd_wr_strobe = snescmd_enable & SNES_wr_strobe;

reg feat_cmd_unlock; always @(posedge clk) feat_cmd_unlock <= feat_cmd_unlock_in;
reg cheat_enable = 0;
reg nmi_enable = 0;
reg irq_enable = 0;
reg holdoff_enable = 0; // temp disable hooks after reset
reg buttons_enable = 0;
reg wram_present = 0;
reg savestate_enable = 0;
wire branch_wram = cheat_enable & wram_present;

reg auto_nmi_enable = 1;
reg auto_irq_enable = 0;
reg auto_nmi_enable_sync = 0;
reg auto_irq_enable_sync = 0;
reg hook_enable_sync = 0;

reg [1:0] sync_delay = 2'b10;

reg [4:0] nmi_usage = 5'h00;
reg [4:0] irq_usage = 5'h00;
reg [20:0] usage_count = 21'h1fffff;

reg [29:0] hook_enable_count = 0;

reg [1:0] vector_unlock_r = 0;
wire vector_unlock = |vector_unlock_r;

reg [1:0] reset_unlock_r = 2'b10;
wire reset_unlock = |reset_unlock_r;

reg [23:0] cheat_addr[5:0];
reg [7:0] cheat_data[5:0];
reg [5:0] cheat_enable_mask;

reg exe_unlock_r; initial exe_unlock_r = 0;
assign exe_unlock = exe_unlock_r;
reg exe_to_hook_transition_r; initial exe_to_hook_transition_r = 0;

reg snescmd_unlock_r = 0;
assign snescmd_unlock = snescmd_unlock_r | exe_unlock_r;

reg map_unlock_r = 0;
assign map_unlock = map_unlock_r;

reg [7:0] nmicmd = 0;
reg [7:0] return_vector = 8'hea;

reg [7:0] branch1_offset = 8'h00;
reg [7:0] branch2_offset = 8'h00;
reg [7:0] branch3_offset = 8'h00;

reg [15:0] pad_data = 0;

wire [5:0] cheat_match_bits ={(cheat_enable_mask[5] & (SNES_ADDR == cheat_addr[5])),
                              (cheat_enable_mask[4] & (SNES_ADDR == cheat_addr[4])),
                              (cheat_enable_mask[3] & (SNES_ADDR == cheat_addr[3])),
                              (cheat_enable_mask[2] & (SNES_ADDR == cheat_addr[2])),
                              (cheat_enable_mask[1] & (SNES_ADDR == cheat_addr[1])),
                              (cheat_enable_mask[0] & (SNES_ADDR == cheat_addr[0]))};
wire cheat_addr_match = |cheat_match_bits;

wire [1:0] nmi_match_bits = {SNES_ADDR == 24'h00FFEA, SNES_ADDR == 24'h00FFEB};
wire [1:0] irq_match_bits = {SNES_ADDR == 24'h00FFEE, SNES_ADDR == 24'h00FFEF};
wire [1:0] rst_match_bits = {SNES_ADDR == 24'h00FFFC, SNES_ADDR == 24'h00FFFD};

wire nmi_addr_match = |nmi_match_bits;
wire irq_addr_match = |irq_match_bits;
wire rst_addr_match = |rst_match_bits;

wire hook_enable = ~|hook_enable_count;

assign data_out = cheat_match_bits[0] ? cheat_data[0]
                : cheat_match_bits[1] ? cheat_data[1]
                : cheat_match_bits[2] ? cheat_data[2]
                : cheat_match_bits[3] ? cheat_data[3]
                : cheat_match_bits[4] ? cheat_data[4]
                : cheat_match_bits[5] ? cheat_data[5]
                // exe code
                : (exe_present & nmi_match_bits[0] & exe_unlock) ? 8'h2C
                : (exe_present & nmi_match_bits[1] & exe_unlock) ? 8'h00
                : nmi_match_bits[1] ? 8'h10
                : irq_match_bits[1] ? 8'h10
                : rst_match_bits[1] ? 8'h7D
                : nmicmd_enable ? nmicmd
                : return_vector_enable ? return_vector
                : branch1_enable ? branch1_offset
                : branch2_enable ? branch2_offset
                : branch3_enable ? branch3_offset
                : 8'h2a;

/// TODO separate cheat and nmi branch patch signals
/// "cheat" must patch branch targets in NMI hook
/// BUT MUST NOT apply actual ROM cheat patches during snescmd menu bank
/// execution to prevent ROM cheats from patching nonsense into the savestate
/// handler.
/// this is caused by C0-FF bank overlay. Probably not a good idea.
assign cheat_hit = (snescmd_unlock & hook_enable_sync & (nmicmd_enable | return_vector_enable | branch1_enable | branch2_enable | branch3_enable))
                   | (reset_unlock & rst_addr_match)
                   | (cheat_enable & cheat_addr_match & ~snescmd_unlock)
                   | (hook_enable_sync & (((auto_nmi_enable_sync & (nmi_enable|(exe_present & ~feat_cmd_unlock))) & nmi_addr_match & vector_unlock) // exe or NMI can get us started
                                           |(auto_nmi_enable_sync & nmi_enable & nmi_addr_match & exe_to_hook_transition_r)              // exe exit can also trigger hook
                                           |((auto_irq_enable_sync & irq_enable) & irq_addr_match & vector_unlock)));

// irq/nmi detect based on CPU access pattern
// 4 writes (mirrored to B bus) signify that the CPU pushes PB, PC and
// SR to the stack and is going to read the vector address in the next
// two cycles.
// B bus mirror is used (combined with A BUS /WR!) so the write pattern
// cannot be confused with backwards DMA transfers.

reg [7:0] next_pa_addr = 0;
reg [2:0] cpu_push_cnt = 0;

always @(posedge clk) begin
  if(SNES_reset_strobe) begin
    cpu_push_cnt <= 0;
  end else if(SNES_wr_strobe) begin
    cpu_push_cnt <= cpu_push_cnt + 1;
    if(cpu_push_cnt == 3'b0) begin
      next_pa_addr <= SNES_PA - 1;
    end else begin
      if(SNES_PA == next_pa_addr) begin
         next_pa_addr <= next_pa_addr - 1;
      end else begin
        cpu_push_cnt <= 3'b0;
      end
    end
  end else if(SNES_rd_strobe) begin
    cpu_push_cnt <= 3'b0;
  end
end

// make patched vectors visible for last cycles of NMI/IRQ handling only
always @(posedge clk) begin
  if(SNES_reset_strobe) begin
    vector_unlock_r <= 2'b00;
  end else if(SNES_rd_strobe) begin
    if(hook_enable_sync
      & ((auto_nmi_enable_sync & (nmi_enable|(exe_present & ~feat_cmd_unlock)) & nmi_match_bits[1])
        |(auto_irq_enable_sync & irq_enable & irq_match_bits[1]))
      & cpu_push_cnt == 4) begin
      vector_unlock_r <= 2'b11;
    end else if(|vector_unlock_r) begin
      vector_unlock_r <= vector_unlock_r - 1;
    end
  end
end

// make patched reset vector visible for first fetch only
// (including masked read by Ultra16)
always @(posedge clk) begin
  if(SNES_reset_strobe) begin
    reset_unlock_r <= 2'b11;
  end else if(SNES_cycle_start) begin
    if(rst_addr_match & |reset_unlock_r) begin
      reset_unlock_r <= reset_unlock_r - 1;
    end
  end
end

reg snescmd_unlock_disable_strobe = 1'b0;
reg [6:0] snescmd_unlock_disable_countdown = 0;
reg snescmd_unlock_disable = 0;

always @(posedge clk) begin
  if(SNES_reset_strobe) begin
    snescmd_unlock_r <= 0;
    snescmd_unlock_disable <= 0;
    map_unlock_r <= 0;
    exe_to_hook_transition_r <= 0;
  end else begin
    if (~nmi_addr_match)   exe_to_hook_transition_r <= 0;
    else if (map_unlock_r) exe_to_hook_transition_r <= 1;
  
    if(SNES_rd_strobe) begin
      // *** GAME -> USB HOOK ***
      if(hook_enable_sync
        & ((auto_nmi_enable_sync & exe_present & ~feat_cmd_unlock & ~exe_unlock & nmi_match_bits[1]))
        & (cpu_push_cnt == 4)) begin
        // perform exe of $2C00

        // NOTE: only supported on NMI
        // remember where we came from (IRQ/NMI) for hook exit
        return_vector <= SNES_ADDR[7:0];
        // unlock the address map
        map_unlock_r <= 1;
        // unlock exe code
        exe_unlock_r <= 1;
      end
      // *** USB HOOK -> INGAME HOOK ***
      else if (hook_enable_sync & exe_unlock
        & (auto_nmi_enable_sync & nmi_enable & nmi_match_bits[1])
        & (cpu_push_cnt != 4)
        ) begin
        // exit exe and jump to snescmd.  pushcnt check guards against nesting calls used by save state
        
        // unlock the snescmd region
        snescmd_unlock_r <= 1;
        // lock the address map
        map_unlock_r <= 0;
        // no longer in exe region
        exe_unlock_r <= 0;        
      end
      // *** USB HOOK -> GAME ***
      else if (exe_unlock & nmi_match_bits[1]
       & (cpu_push_cnt != 4)
       ) begin
        // exit exe and go to NMI handler.  pushcnt check guards against nesting calls used by save state

        exe_unlock_r <= 0;
        map_unlock_r <= 0;
      end
      // *** GAME -> INGAME HOOK ***
      else if(hook_enable_sync
        & ((auto_nmi_enable_sync & nmi_enable & nmi_match_bits[1])
          |(auto_irq_enable_sync & irq_enable & irq_match_bits[1]))
        & cpu_push_cnt == 4) begin
        // no exe, just straight to snescmd

        // remember where we came from (IRQ/NMI) for hook exit
        return_vector <= SNES_ADDR[7:0];
        // unlock the snescmd region
        snescmd_unlock_r <= 1;
      end
      // *** RESET -> RESET HOOK ***
      if(rst_match_bits[1] & |reset_unlock_r) begin
        snescmd_unlock_r <= 1;
      end
    end
    
/// TODO unlock disable on hook exit needs rework, there are potential issues:
///
/// 1. Countdown needs to be short because jumping back to ROM would
///    otherwise yield wrong data (because of bank C0 overlay)
///
/// 2. HDMA can interrupt the IRQ hook after writing the unlock trigger
///    so the number of countdown cycles needed may be much bigger but can't
///    be predicted, so countdown might be too short and disable nmi hook
///    unlock before the CPU can exit. (this happens on Star Fox (2))
///
/// 3. HDMA might access bank $C0 expecting ROM data during unlock but reads
///    menu bank data instead ((( CANNOT FIX --- REVERT C0-FF UNLOCK? )))
///
/// Possible solution:
/// 1. arm disable detection after disable trigger has been written
/// 2. wait for CPU to read 2 vector addresses (FFEA, FFEE, FFFC) and capture
///    the data read from those addresses
/// 3. disarm detection and disable unlock when CPU starts reading the address
///    captured in 2.

    // give some time to exit snescmd memory and jump to original vector
    // sta @NMI_VECT_DISABLE    1-2 (after effective write)
    // jmp ($ffxx)              3 (excluding address fetch)
    // *** (INGAME HOOK -> GAME) ***
    if(SNES_cycle_start) begin
      if(snescmd_unlock_disable) begin
        if(|snescmd_unlock_disable_countdown) begin
          snescmd_unlock_disable_countdown <= snescmd_unlock_disable_countdown - 1;
        end else if(snescmd_unlock_disable_countdown == 0) begin
          snescmd_unlock_r <= 0;
          snescmd_unlock_disable <= 0;
        end
      end
    end
    if(snescmd_unlock_disable_strobe) begin
      snescmd_unlock_disable_countdown <= 7'd6;
      snescmd_unlock_disable <= 1;
    end
  end
end


// Only clock the usage timeout when outside of in-game hook
// to prevent nested IRQs from jumping to game
// (otherwise FPGA might disable hook patching while still inside hook
//  which hurts the current save state handler implementation since it
//  uses IRQ inside IRQ / NMI inside NMI to synchronize with the time of entry)
always @(posedge clk) begin
  if (~snescmd_unlock) begin
    usage_count <= usage_count - 1;
  end
end

// Try and autoselect NMI or IRQ hook
always @(posedge clk) begin
  if(usage_count == 21'b0) begin
    nmi_usage <= SNES_cycle_start & nmi_match_bits[1];
    irq_usage <= SNES_cycle_start & irq_match_bits[1];
    if(|nmi_usage & |irq_usage) begin
      auto_nmi_enable <= 1'b1;
      auto_irq_enable <= 1'b0;
    end else if(irq_usage == 5'b0) begin
      auto_nmi_enable <= 1'b1;
      auto_irq_enable <= 1'b0;
    end else if(nmi_usage == 5'b0) begin
      auto_nmi_enable <= 1'b0;
      auto_irq_enable <= 1'b1;
    end
  end else begin
    if(SNES_cycle_start & nmi_match_bits[0]) nmi_usage <= nmi_usage + 1;
    if(SNES_cycle_start & irq_match_bits[0]) irq_usage <= irq_usage + 1;
  end
end

// Do not change vectors while they are being read
always @(posedge clk) begin
  if(SNES_cycle_start) begin
    if(nmi_addr_match | irq_addr_match) sync_delay <= 2'b10;
    else begin
      if (|sync_delay) sync_delay <= sync_delay - 1;
      if (sync_delay == 2'b00) begin
        auto_nmi_enable_sync <= auto_nmi_enable;
        auto_irq_enable_sync <= auto_irq_enable;
        hook_enable_sync <= hook_enable;
      end
    end
  end
end

// CMD 0x85: disable hooks for 10 seconds
always @(posedge clk) begin
  if((snescmd_unlock & snescmd_wr_strobe & (SNES_ADDR[10:9] == 2'b01) & ~|SNES_ADDR[8:0] & (SNES_DATA == 8'h85))
     | (holdoff_enable & SNES_reset_strobe)) begin
    hook_enable_count <= 30'd960000000;
  end else if (|hook_enable_count) begin
    hook_enable_count <= hook_enable_count - 1;
  end
end

always @(posedge clk) begin
  if(SNES_reset_strobe) begin
    snescmd_unlock_disable_strobe <= 1'b0;
  end else begin
    snescmd_unlock_disable_strobe <= 1'b0;
    if(snescmd_unlock & snescmd_wr_strobe) begin
      if((SNES_ADDR[10:9] == 2'b01) && (~|SNES_ADDR[8:0])) begin
        case(SNES_DATA)
          8'h82: cheat_enable <= 1;
          8'h83: cheat_enable <= 0;
          8'h84: {nmi_enable, irq_enable} <= 2'b00;
        endcase
      end else if(SNES_ADDR[10:0] == 11'h3fd) begin
        snescmd_unlock_disable_strobe <= 1'b1;
      end
    end else if(pgm_we) begin
      if(pgm_idx < 6) begin
        cheat_addr[pgm_idx] <= pgm_in[31:8];
        cheat_data[pgm_idx] <= pgm_in[7:0];
      end else if(pgm_idx == 6) begin // set rom patch enable
        cheat_enable_mask <= pgm_in[5:0];
      end else if(pgm_idx == 7) begin // set/reset global enable / hooks
      // pgm_in[15:8] are reset bit flags
      // pgm_in[7:0] are set bit flags
        {savestate_enable, wram_present, buttons_enable, holdoff_enable, irq_enable, nmi_enable, cheat_enable}
         <= ({savestate_enable, wram_present, buttons_enable, holdoff_enable, irq_enable, nmi_enable, cheat_enable}
          & ~pgm_in[14:8])
          | pgm_in[6:0];
      end
    end
  end
end

// map controller input to cmd output
// check button combinations
// L+R+Start+Select : $3030
// L+R+Select+X     : $2070
// L+R+Start+A      : $10b0
// L+R+Start+B      : $9030
// L+R+Start+Y      : $5030
// L+R+Start+X      : $1070
always @(posedge clk) begin
  if(snescmd_wr_strobe) begin
    if(SNES_ADDR[10:0] == 11'h3f0) begin          // $2BF0
      pad_data[7:0] <= SNES_DATA;
    end else if(SNES_ADDR[10:0] == 11'h3f1) begin // $2BF1
      pad_data[15:8] <= SNES_DATA;
    end
  end
end

always @* begin
  case(pad_data)
    16'h3030: nmicmd = 8'h80;
    16'h2070: nmicmd = 8'h81;
    16'h10b0: nmicmd = 8'h82;
    16'h9030: nmicmd = 8'h83;
    16'h5030: nmicmd = 8'h84;
    16'h1070: nmicmd = 8'h85;
    default: nmicmd = 8'h00;
  endcase
end

always @* begin
  if(buttons_enable) begin
    if(snes_ajr) begin
      if(nmicmd) begin
        branch1_offset = 8'h30;   // nmi_echocmd
      end else begin
        if(branch_wram) begin
          branch1_offset = 8'h3a; // nmi_patches
        end else begin
          if(savestate_enable & |pad_data) begin
            branch1_offset = 8'h3f; // nmi_savestate
          end else begin
            branch1_offset = 8'h43; // nmi_exit
          end
        end
      end
    end else begin // no AJR -> read the pad manually
      if(pad_latch) begin
      // game is in progress of manual controller polling (4016)
      // -> do nothing to avoid disturbing the bit shift count
      // no known buttons -> no point in calling savestate handler
        if(branch_wram) begin
          branch1_offset = 8'h3a; // nmi_patches
        end else begin
          branch1_offset = 8'h43; // nmi_exit
        end
      end else begin
        branch1_offset = 8'h00;   // continue with MJR
      end
    end
  end else begin
    if(branch_wram) begin
      branch1_offset = 8'h3a;     // nmi_patches
    end else begin
      if(savestate_enable & |pad_data) begin
        branch1_offset = 8'h3f;   // nmi_savestate
      end else begin
        branch1_offset = 8'h43;   // nmi_exit
      end
    end
  end
end

always @* begin
  if(nmicmd == 8'h81) begin
    branch2_offset = 8'h14;       // nmi_stop
  end else if(branch_wram) begin
    branch2_offset = 8'h00;       // nmi_patches
  end else begin
    if(savestate_enable) begin
      branch2_offset = 8'h05;     // nmi_savestate
    end else begin
      branch2_offset = 8'h09;     // nmi_exit
    end
  end
end

always @* begin
  if(savestate_enable) begin
    branch3_offset = 8'h00;       // nmi_savestate
  end else begin
    branch3_offset = 8'h04;       // nmi_exit
  end
end

endmodule
