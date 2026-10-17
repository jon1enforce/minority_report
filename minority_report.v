//#############################################################################
// minority_report.v
// Finale, korrigierte Version mit zwei Ausgabe-Lanes:
//   Lane 1: 20 Bit = {valid_mantissa_bits[3:0], majority_value[15:0]}
//   Lane 2: 20 Bit = 5 x 4 Bit Minoritaets-Statistik
//
// Korrekturen gegenueber der Vorgaenger-Version:
//   1. Auswahl-Schleife laeuft von s=0 nach s=9 (groesste Bitlaenge gewinnt).
//   2. idx als integer deklariert (keine negativen Werte als reg[3:0]).
//   3. Sinnlose if-Abfrage in step_meta entfernt.
//   4. force_error_meta entfernt (toter Code).
//
// Minoritaets-Statistik (pro Kuerzungsschritt):
//   0000 = keine Kuerzung, Majority sofort akzeptiert
//   0001 = 1 Abweichler (akzeptiert, kein Kuerzen)
//   0010..1110 = Anzahl Abweichler bei diesem Kuerzungsschritt
//   1111 = Fehlerfall (Vorzeichen/Exponent abweichend ODER alles gekuerzt)
//#############################################################################

module minority_report #(
    parameter NUM_INPUTS = 18,
    parameter CNT_W      = $clog2(NUM_INPUTS + 1)
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // Paralleler Eingang
    input  wire                    in_valid,
    input  wire [NUM_INPUTS*16-1:0] in_values_flat,

    // Ausgang Lane 1: finaler Wert + Valid-Bits
    output reg                     out_valid,
    output reg  [19:0]             majority_packed,

    // Ausgang Lane 2: Minoritaets-Statistik
    output reg  [19:0]             minority_meta,

    // Zusatz-Flags (optional, fuer Debug)
    output reg                     error_sign,
    output reg                     error_exp,
    output reg                     no_majority
);

    //-------------------------------------------------------------------------
    // Werte entpacken
    //-------------------------------------------------------------------------
    wire [15:0] values [0:NUM_INPUTS-1];
    wire [NUM_INPUTS-1:0] signs;
    wire [4:0]            exps  [0:NUM_INPUTS-1];
    wire [9:0]            mants [0:NUM_INPUTS-1];

    genvar g;
    generate
        for (g = 0; g < NUM_INPUTS; g = g + 1) begin : g_split
            assign values[g] = in_values_flat[g*16 +: 16];
            assign signs[g]  = values[g][15];
            assign exps[g]   = values[g][14:10];
            assign mants[g]  = values[g][9:0];
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Vorzeichen: Majority + Fehler
    //-------------------------------------------------------------------------
    integer k;
    reg [CNT_W-1:0] sign_ones;
    always @(*) begin
        sign_ones = {CNT_W{1'b0}};
        for (k = 0; k < NUM_INPUTS; k = k + 1)
            if (signs[k]) sign_ones = sign_ones + 1'b1;
    end

    wire sign_majority = (sign_ones > NUM_INPUTS/2);
    wire sign_ok       = (sign_ones == 0) || (sign_ones == NUM_INPUTS);

    //-------------------------------------------------------------------------
    // Exponent: Majority + Fehler
    //-------------------------------------------------------------------------
    integer a, b;
    reg [CNT_W-1:0] exp_max;
    reg [4:0]       exp_best;
    reg [CNT_W-1:0] exp_cnt;
    always @(*) begin
        exp_max  = {CNT_W{1'b0}};
        exp_best = 5'd0;
        for (a = 0; a < NUM_INPUTS; a = a + 1) begin
            exp_cnt = {CNT_W{1'b0}};
            for (b = 0; b < NUM_INPUTS; b = b + 1)
                if (exps[a] == exps[b]) exp_cnt = exp_cnt + 1'b1;
            if (exp_cnt > exp_max) begin
                exp_max  = exp_cnt;
                exp_best = exps[a];
            end
        end
    end

    wire exp_ok = (exp_max == NUM_INPUTS);

    //-------------------------------------------------------------------------
    // Mantisse: Majority-Kuerzung -- parallel fuer alle 10 Bitlaengen
    //-------------------------------------------------------------------------
    function [9:0] shrink_mant;
        input [9:0] v;
        input [3:0] bl;
        integer i;
        begin
            shrink_mant = 10'd0;
            for (i = 0; i < 10; i = i + 1)
                if (i < bl) shrink_mant[i] = v[i];
        end
    endfunction

    function equal_mant;
        input [9:0] x;
        input [9:0] y;
        input [3:0] bl;
        integer i;
        reg eq;
        begin
            eq = 1'b1;
            for (i = 0; i < 10; i = i + 1)
                if (i < bl && x[i] != y[i]) eq = 1'b0;
            equal_mant = eq;
        end
    endfunction

    // Pro Bitlaenge bl=1..10: Majority-Wert und Abweichlerzahl
    reg [9:0]       mbest  [0:9];
    reg [CNT_W-1:0] mabweich [0:9];

    integer p, q, bl_idx;
    reg [CNT_W-1:0] mcnt, mmax;
    reg [9:0]       mval;
    reg [3:0]       bl;

    always @(*) begin
        for (bl_idx = 0; bl_idx < 10; bl_idx = bl_idx + 1) begin
            bl = bl_idx + 1;
            mmax = {CNT_W{1'b0}};
            mval = 10'd0;
            for (p = 0; p < NUM_INPUTS; p = p + 1) begin
                mcnt = {CNT_W{1'b0}};
                for (q = 0; q < NUM_INPUTS; q = q + 1)
                    if (equal_mant(mants[p], mants[q], bl))
                        mcnt = mcnt + 1'b1;
                if (mcnt > mmax) begin
                    mmax = mcnt;
                    mval = mants[p];
                end
            end
            mbest[bl_idx]    = mval;
            mabweich[bl_idx] = NUM_INPUTS[CNT_W-1:0] - mmax;
        end
    end

    //-------------------------------------------------------------------------
    // Auswahl: groesste Bitlaenge mit abweichler <= 1
    // Schleife laeuft von s=0 nach s=9, der LETZTE Treffer gewinnt
    // (das ist die groesste Bitlaenge).
    //-------------------------------------------------------------------------
    reg [3:0]       chosen_bl;
    reg [9:0]       chosen_mant;
    reg             chosen_no_majority;
    integer s;

    always @(*) begin
        chosen_bl          = 4'd1;
        chosen_mant        = mbest[0];
        chosen_no_majority = 1'b1;
        for (s = 0; s < 10; s = s + 1) begin
            if (mabweich[s] <= 1) begin
                chosen_bl          = s + 1;
                chosen_mant        = mbest[s];
                chosen_no_majority = 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Minoritaets-Statistik: 5 Nibbles
    //-------------------------------------------------------------------------
    reg [3:0] step_meta [0:9];
    integer t;

    always @(*) begin
        for (t = 0; t < 10; t = t + 1)
            step_meta[t] = mabweich[t][3:0];
    end

    // Auswahl der letzten 5 Schritte (bis zur chosen_bl)
    reg [19:0] meta_packed;
    integer u, idx;

    always @(*) begin
        meta_packed = 20'd0;
        for (u = 0; u < 5; u = u + 1) begin
            idx = chosen_bl - 1 - u;
            if (idx >= 0 && idx < 10)
                meta_packed[(4-u)*4 +: 4] = step_meta[idx];
            else
                meta_packed[(4-u)*4 +: 4] = 4'd0;
        end
    end

    //-------------------------------------------------------------------------
    // Ausgabe-Register
    //-------------------------------------------------------------------------
    reg in_valid_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid       <= 1'b0;
            majority_packed <= 20'd0;
            minority_meta   <= 20'd0;
            error_sign      <= 1'b0;
            error_exp       <= 1'b0;
            no_majority     <= 1'b0;
            in_valid_d      <= 1'b0;
        end
        else begin
            in_valid_d <= in_valid;

            if (in_valid_d) begin
                out_valid  <= 1'b1;
                error_sign <= !sign_ok;
                error_exp  <= !exp_ok;

                if (!sign_ok || !exp_ok) begin
                    // Fehlerfall: Vorzeichen oder Exponent abweichend
                    majority_packed <= {4'd0, sign_majority, exp_best, 10'd0};
                    minority_meta   <= 20'hFFFFF;   // Extremfall
                    no_majority     <= 1'b0;
                end
                else if (chosen_no_majority && chosen_bl <= 1) begin
                    // Keine Majority: alles gekuerzt
                    majority_packed <= {4'd1, sign_majority, exp_best, chosen_mant};
                    minority_meta   <= 20'hFFFFF;
                    no_majority     <= 1'b1;
                end
                else begin
                    // Normalfall
                    majority_packed <= {chosen_bl, sign_majority, exp_best, chosen_mant};
                    minority_meta   <= meta_packed;
                    no_majority     <= 1'b0;
                end
            end
            else begin
                out_valid <= 1'b0;
            end
        end
    end

endmodule