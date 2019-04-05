// Copyright lowRISC contributors.
// Copyright 2018 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Matthias Baer - baermatt@student.ethz.ch                   //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Andreas Traber - atraber@student.ethz.ch                   //
//                 Sven Stucki - svstucki@student.ethz.ch                     //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                                                                            //
// Design Name:    Main controller                                            //
// Project Name:   ibex                                                       //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Main CPU controller of the processor                       //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

`include "ibex_config.sv"

/**
 * Main CPU controller of the processor
 */
module ibex_controller (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        fetch_enable_i,             // Start the decoding
    output logic        ctrl_busy_o,                // Core is busy processing instructions
    output logic        first_fetch_o,              // Core is at the FIRST FETCH stage
    output logic        is_decoding_o,              // Core is in decoding state

    // decoder related signals
    output logic        deassert_we_o,              // deassert write enable for next instruction

    input  logic        illegal_insn_i,             // decoder encountered an invalid instruction
    input  logic        ecall_insn_i,               // ecall encountered an mret instruction
    input  logic        mret_insn_i,                // decoder encountered an mret instruction
    input  logic        dret_insn_i,                // decoder encountered an dret instruction
    input  logic        pipe_flush_i,               // decoder wants to do a pipe flush
    input  logic        ebrk_insn_i,                // decoder encountered an ebreak instruction
    input  logic        csr_status_i,               // decoder encountered an csr status instruction

    // from IF/ID pipeline
    input  logic        instr_valid_i,              // instruction coming from IF/ID pipeline is
                                                    // valid

    // from prefetcher
    output logic        instr_req_o,                // Start fetching instructions

    // to prefetcher
    output logic        pc_set_o,                   // jump to address set by pc_mux
    output logic [2:0]  pc_mux_o,                   // Selector in the Fetch stage to select the
                                                    // right PC (normal, jump ...)
    output logic [2:0]  exc_pc_mux_o,               // Selects target PC for exception

    // LSU
    input  logic        data_misaligned_i,

    // jump/branch signals
    input  logic        branch_in_id_i,             // branch in id
    input  logic        branch_taken_ex_i,          // branch taken signal
    input  logic        branch_set_i,               // branch taken set signal
    input  logic        jump_set_i,                 // jump taken set signal

    input  logic        instr_multicyle_i,          // multicycle instructions active

    // External Interrupt Req Signals, used to wake up from wfi even if the interrupt is not taken
    input  logic        irq_i,
    // Interrupt Controller Signals
    input  logic        irq_req_ctrl_i,
    input  logic [4:0]  irq_id_ctrl_i,
    input  logic        m_IE_i,                     // interrupt enable bit from CSR (M mode)

    output logic        irq_ack_o,
    output logic [4:0]  irq_id_o,

    output logic [5:0]  exc_cause_o,
    output logic        exc_ack_o,
    output logic        exc_kill_o,

    // Debug Signal
    input  logic        debug_req_i,

    output logic        csr_save_if_o,
    output logic        csr_save_id_o,
    output logic [5:0]  csr_cause_o,
    output logic        csr_restore_mret_id_o,
    output logic        csr_restore_dret_id_o,
    output logic        csr_save_cause_o,

    // forwarding signals
    output logic [1:0]  operand_a_fw_mux_sel_o,   // regfile ra data selector form ID stage

    // stall signals
    output logic        halt_if_o,
    output logic        halt_id_o,

    input  logic        id_ready_i,               // ID stage is ready

    // Performance Counters
    output logic        perf_jump_o,              // we are executing a jump instruction
                                                  // (j, jr, jal, jalr)
    output logic        perf_tbranch_o            // we are executing a taken branch instruction
);
  import ibex_defines::*;

  // FSM state encoding
  typedef enum logic [3:0] {
    RESET, BOOT_SET, WAIT_SLEEP, SLEEP, FIRST_FETCH, DECODE, FLUSH,
    IRQ_TAKEN, DBG_TAKEN
  } ctrl_fsm_e;

  ctrl_fsm_e ctrl_fsm_cs, ctrl_fsm_ns;

  logic irq_enable_int;

  logic debug_mode_q, debug_mode_n;

`ifndef SYNTHESIS
  // synopsys translate_off
  // make sure we are called later so that we do not generate messages for
  // glitches
  always_ff @(negedge clk) begin
    // print warning in case of decoding errors
    if (is_decoding_o && illegal_insn_i) begin
      $display("%t: Illegal instruction (core %0d) at PC 0x%h: 0x%h", $time, ibex_core.core_id_i,
               ibex_id_stage.pc_id_i, ibex_id_stage.instr_rdata_i);
    end
  end
  // synopsys translate_on
`endif


  ////////////////////////////////////////////////////////////////////////////////////////////
  //   ____ ___  ____  _____    ____ ___  _   _ _____ ____   ___  _     _     _____ ____    //
  //  / ___/ _ \|  _ \| ____|  / ___/ _ \| \ | |_   _|  _ \ / _ \| |   | |   | ____|  _ \   //
  // | |  | | | | |_) |  _|   | |  | | | |  \| | | | | |_) | | | | |   | |   |  _| | |_) |  //
  // | |__| |_| |  _ <| |___  | |__| |_| | |\  | | | |  _ <| |_| | |___| |___| |___|  _ <   //
  //  \____\___/|_| \_\_____|  \____\___/|_| \_| |_| |_| \_\\___/|_____|_____|_____|_| \_\  //
  //                                                                                        //
  ////////////////////////////////////////////////////////////////////////////////////////////


  always_comb begin
    // Default values
    instr_req_o            = 1'b1;

    exc_ack_o              = 1'b0;
    exc_kill_o             = 1'b0;

    csr_save_if_o          = 1'b0;
    csr_save_id_o          = 1'b0;
    csr_restore_mret_id_o  = 1'b0;

    csr_restore_dret_id_o  = 1'b0;

    csr_save_cause_o       = 1'b0;

    exc_cause_o            = '0;
    exc_pc_mux_o           = EXC_PC_IRQ;

    csr_cause_o            = '0;

    pc_mux_o               = PC_BOOT;
    pc_set_o               = 1'b0;

    ctrl_fsm_ns            = ctrl_fsm_cs;

    ctrl_busy_o            = 1'b1;
    is_decoding_o          = 1'b0;
    first_fetch_o          = 1'b0;

    halt_if_o              = 1'b0;
    halt_id_o              = 1'b0;
    irq_ack_o              = 1'b0;
    irq_id_o               = irq_id_ctrl_i;
    irq_enable_int         = m_IE_i;

    debug_mode_n           = debug_mode_q;

    perf_tbranch_o         = 1'b0;
    perf_jump_o            = 1'b0;

    unique case (ctrl_fsm_cs)
      // We were just reset, wait for fetch_enable
      RESET: begin
        instr_req_o   = 1'b0;
        pc_mux_o      = PC_BOOT;
        pc_set_o      = 1'b1;
        if (fetch_enable_i) begin
          ctrl_fsm_ns = BOOT_SET;
        end else if (debug_req_i && !debug_mode_q) begin
          ctrl_fsm_ns  = DBG_TAKEN;
          debug_mode_n = 1'b1;
        end
      end

      // copy boot address to instr fetch address
      BOOT_SET: begin
        instr_req_o   = 1'b1;
        pc_mux_o      = PC_BOOT;
        pc_set_o      = 1'b1;

        ctrl_fsm_ns = FIRST_FETCH;
      end

      WAIT_SLEEP: begin
        ctrl_busy_o   = 1'b0;
        instr_req_o   = 1'b0;
        halt_if_o     = 1'b1;
        halt_id_o     = 1'b1;
        ctrl_fsm_ns   = SLEEP;
      end

      // instruction in if_stage is already valid
      SLEEP: begin
        // we begin execution when an
        // interrupt has arrived
        ctrl_busy_o   = 1'b0;
        instr_req_o   = 1'b0;
        halt_if_o     = 1'b1;
        halt_id_o     = 1'b1;

        // normal execution flow
        if (irq_i || (debug_req_i && !debug_mode_q)) begin
          ctrl_fsm_ns  = FIRST_FETCH;
          debug_mode_n = 1'b1;
        end
      end

      FIRST_FETCH: begin
        first_fetch_o = 1'b1;
        // Stall because of IF miss
        if (id_ready_i) begin
          ctrl_fsm_ns = DECODE;
        end

        // handle interrupts
        if (irq_req_ctrl_i && irq_enable_int) begin
          // This assumes that the pipeline is always flushed before
          // going to sleep.
          ctrl_fsm_ns = IRQ_TAKEN;
          halt_if_o   = 1'b1;
          halt_id_o   = 1'b1;
        end

        // enter debug mode
        if (debug_req_i && !debug_mode_q) begin
          debug_mode_n = 1'b1;

          ctrl_fsm_ns  = DBG_TAKEN;
          halt_if_o    = 1'b1;
          halt_id_o    = 1'b1;
        end
      end

      DECODE: begin
        is_decoding_o = 1'b0;

        /*
         * TODO: What should happen on
         * instr_valid_i && (instr_multicyle_i || branch_in_id_i)?
         * Let the instruction finish executing before serving debug or
         * interrupt requests?
         */

        unique case (1'b1)
          debug_req_i && !debug_mode_q: begin
            // Enter debug mode from external request
            halt_if_o     = 1'b1;
            halt_id_o     = 1'b1;
            ctrl_fsm_ns   = DBG_TAKEN;
            debug_mode_n  = 1'b1;
          end

          irq_req_ctrl_i && irq_enable_int: begin
            // Serve an interrupt
            ctrl_fsm_ns = IRQ_TAKEN;
            halt_if_o   = 1'b1;
            halt_id_o   = 1'b1;
          end

          default: begin
            exc_kill_o    = irq_req_ctrl_i & ~instr_multicyle_i & ~branch_in_id_i;

            if (instr_valid_i) begin
              // analyze the current instruction in the ID stage
              is_decoding_o = 1'b1;

              unique case (1'b1)
                branch_set_i || jump_set_i: begin
                  pc_mux_o       = PC_JUMP;
                  pc_set_o       = 1'b1;

                  perf_tbranch_o = branch_set_i;
                  perf_jump_o    = jump_set_i;
                end

                mret_insn_i || dret_insn_i || ecall_insn_i || pipe_flush_i ||
                ebrk_insn_i || illegal_insn_i || csr_status_i: begin
                  ctrl_fsm_ns = FLUSH;
                  halt_if_o   = 1'b1;
                  halt_id_o   = 1'b1;
                end
              endcase
            end
          end
        endcase
      end

      IRQ_TAKEN: begin
        pc_mux_o          = PC_EXCEPTION;
        pc_set_o          = 1'b1;

        exc_pc_mux_o      = EXC_PC_IRQ;
        exc_cause_o       = {1'b0,irq_id_ctrl_i};

        csr_save_cause_o  = 1'b1;
        csr_cause_o       = {1'b1,irq_id_ctrl_i};

        csr_save_if_o     = 1'b1;

        irq_ack_o         = 1'b1;
        exc_ack_o         = 1'b1;

        ctrl_fsm_ns       = DECODE;
      end

      DBG_TAKEN: begin
        pc_mux_o          = PC_EXCEPTION;
        pc_set_o          = 1'b1;

        exc_pc_mux_o      = EXC_PC_DBD;
        // XXX: most likely wrong
        exc_cause_o       = {1'b0,irq_id_ctrl_i};

        csr_save_cause_o  = ebrk_insn_i ? 1'b0: 1'b1;
        //csr_cause_o       = {1'b1,irq_id_ctrl_i};

        csr_save_if_o     = 1'b1;

        exc_ack_o         = 1'b1;

        ctrl_fsm_ns       = DECODE;
      end

      // flush the pipeline, insert NOP
      FLUSH: begin

        halt_if_o = 1'b1;
        halt_id_o = 1'b1;

        if (!pipe_flush_i) begin
          ctrl_fsm_ns = DECODE;
        end else begin
          ctrl_fsm_ns = WAIT_SLEEP;
        end

        unique case(1'b1)
          ecall_insn_i: begin
            //ecall
            pc_mux_o              = PC_EXCEPTION;
            pc_set_o              = 1'b1;
            csr_save_id_o         = 1'b1;
            csr_save_cause_o      = 1'b1;
            exc_pc_mux_o          = EXC_PC_ECALL;
            exc_cause_o           = EXC_CAUSE_ECALL_MMODE;
            csr_cause_o           = EXC_CAUSE_ECALL_MMODE;
          end
          illegal_insn_i: begin
            //exceptions
            pc_mux_o              = PC_EXCEPTION;
            pc_set_o              = 1'b1;
            csr_save_id_o         = 1'b1;
            csr_save_cause_o      = 1'b1;
            if (debug_mode_q) begin
              exc_pc_mux_o          = EXC_PC_DBGEXC;
            end else begin
              exc_pc_mux_o          = EXC_PC_ILLINSN;
            end
            exc_cause_o           = EXC_CAUSE_ILLEGAL_INSN;
            csr_cause_o           = EXC_CAUSE_ILLEGAL_INSN;
          end
          mret_insn_i: begin
            //mret
            pc_mux_o              = PC_ERET;
            pc_set_o              = 1'b1;
            csr_restore_mret_id_o = 1'b1;
          end
          dret_insn_i: begin
            //dret
            pc_mux_o              = PC_DRET;
            pc_set_o              = 1'b1;
            debug_mode_n          = 1'b0;
            csr_restore_dret_id_o = 1'b1;
          end
          ebrk_insn_i: begin
            //ebreak
            if (debug_mode_q) begin
              /*
               * ebreak in debug mode re-enters debug mode
               *
               * "The only exception is ebreak. When that is executed in Debug
               * Mode, it halts the hart again but without updating dpc or
               * dcsr." [RISC-V Debug Specification v0.13.1, p. 41]
               */
              ctrl_fsm_ns = DBG_TAKEN;
            end else begin
              ctrl_fsm_ns = DECODE;
            end
          end
          default:;
        endcase
      end

      default: begin
        instr_req_o = 1'b0;
        ctrl_fsm_ns = RESET;
      end
    endcase
  end

  /////////////////////////////////////////////////////////////
  //  ____  _        _ _    ____            _             _  //
  // / ___|| |_ __ _| | |  / ___|___  _ __ | |_ _ __ ___ | | //
  // \___ \| __/ _` | | | | |   / _ \| '_ \| __| '__/ _ \| | //
  //  ___) | || (_| | | | | |__| (_) | | | | |_| | | (_) | | //
  // |____/ \__\__,_|_|_|  \____\___/|_| |_|\__|_|  \___/|_| //
  //                                                         //
  /////////////////////////////////////////////////////////////

  // deassert WE when the core is not decoding instructions
  // or in case of illegal instruction
  assign deassert_we_o = ~is_decoding_o | illegal_insn_i;

  // Forwarding control unit
  assign operand_a_fw_mux_sel_o = data_misaligned_i ? SEL_MISALIGNED : SEL_REGFILE;

  // update registers
  always_ff @(posedge clk, negedge rst_n) begin : UPDATE_REGS
    if (!rst_n) begin
      ctrl_fsm_cs <= RESET;
      //jump_done_q <= 1'b0;
      debug_mode_q   <= 1'b0;
    end else begin
      ctrl_fsm_cs <= ctrl_fsm_ns;
      // clear when id is valid (no instruction incoming)
      //jump_done_q <= jump_done & (~id_ready_i);
      debug_mode_q   <=  debug_mode_n; //1'b0;
    end
  end
endmodule // controller