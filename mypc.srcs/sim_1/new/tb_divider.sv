`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 除算IP(Divider Generator)の振る舞いモデル．ブロックダイアグラム上の除算IPと同じく，
// 被除数・除数のtvalidが両方立ったサイクルの入力を受け付け，LATENCYサイクル後にdout_tvalidを
// 1サイクルだけ立てる．dout_tdataは上位32ビットが商，下位32ビットが余りで，次の結果が出るまで前回の値を保持する．
// 実物のIPを使わないのは，シミュレーションをブロックダイアグラムの出力生成物に依存させないため
//////////////////////////////////////////////////////////////////////////////////


module tb_divider #(
    parameter int LATENCY   = 36,  // 入力を受け付けてから結果が出るまでのサイクル数(2以上)
    parameter bit IS_SIGNED = 1    // 1なら符号あり，0なら符号なしの除算を行う
    ) (
    input  logic        aclk,
    input  logic [31:0] s_axis_divisor_tdata,
    input  logic        s_axis_divisor_tvalid,
    input  logic [31:0] s_axis_dividend_tdata,
    input  logic        s_axis_dividend_tvalid,
    output logic [63:0] m_axis_dout_tdata = '0,
    output logic        m_axis_dout_tvalid = 1'b0
    );

    logic [63:0] result_pipe[0:LATENCY - 2] = '{default: '0};  // 計算結果を出力まで遅らせるシフトレジスタ
    logic        valid_pipe [0:LATENCY - 2] = '{default: 1'b0}; // 各段の計算結果が有効か

    // 商と余りを求める．符号ありでは0方向へ切り捨て，余りの符号は被除数に従う(SystemVerilogの/と%に同じ)
    function automatic logic [63:0] divide(input logic [31:0] dividend, input logic [31:0] divisor);
        // 0除算はCPUが除算IPへ送らないため扱わない
        if (divisor == '0)
            return 'x;
        // 符号ありの最小値を-1で割ると商が32ビットに収まらず，シミュレータの演算結果も保証されない．
        // 仕様上結果は不定のため，ここでは桁あふれした商(最小値)と余り0を返す
        if (IS_SIGNED && dividend == 32'h8000_0000 && divisor == 32'hffff_ffff)
            return {32'h8000_0000, 32'h0};
        if (IS_SIGNED)
            return {32'($signed(dividend) / $signed(divisor)), 32'($signed(dividend) % $signed(divisor))};
        return {dividend / divisor, dividend % divisor};
    endfunction

    always_ff @(posedge aclk) begin
        // 両方の入力が揃ったサイクルに計算し，シフトレジスタの先頭へ入れる
        valid_pipe[0]  <= s_axis_divisor_tvalid && s_axis_dividend_tvalid;
        result_pipe[0] <= (s_axis_divisor_tvalid && s_axis_dividend_tvalid)
            ? divide(s_axis_dividend_tdata, s_axis_divisor_tdata) : '0;

        // 1段ずつ後ろへ送る
        for (int i = 1; i <= LATENCY - 2; i++) begin
            valid_pipe[i]  <= valid_pipe[i - 1];
            result_pipe[i] <= result_pipe[i - 1];
        end

        // 最後の段に届いた有効な結果だけを出力し，それ以外のサイクルは前回の結果を出し続ける
        m_axis_dout_tvalid <= valid_pipe[LATENCY - 2];
        if (valid_pipe[LATENCY - 2])
            m_axis_dout_tdata <= result_pipe[LATENCY - 2];
    end

endmodule
