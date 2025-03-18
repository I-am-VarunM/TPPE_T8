module fast_prefix #(
    parameter BITMASK_WIDTH = 128,
    parameter WEIGHT_WIDTH = 8
)(
    input wire clk,
    input wire rst,
    input wire [BITMASK_WIDTH-1:0] and_result,
    input wire [BITMASK_WIDTH-1:0] bitmask_b,
    input wire valid_match,
    input wire [BITMASK_WIDTH*WEIGHT_WIDTH-1:0] fibre_b_data_flat, // Flattened array input
    output reg [$clog2(BITMASK_WIDTH)-1:0] fast_offset,
    output reg [$clog2(BITMASK_WIDTH)-1:0] matched_position,
    output reg [WEIGHT_WIDTH-1:0] matched_weight,
    output reg fast_valid,
    output reg processing_done
);

    // Create local array to work with the flattened input
    wire [WEIGHT_WIDTH-1:0] fibre_b_data [0:BITMASK_WIDTH-1];
    
    // Convert flat input to array (for internal use)
    genvar i;
    generate
        for (i = 0; i < BITMASK_WIDTH; i = i + 1) begin : gen_array
            assign fibre_b_data[i] = fibre_b_data_flat[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
        end
    endgenerate

    // State machine signals
    reg [BITMASK_WIDTH-1:0] current_and_result;
    reg [BITMASK_WIDTH-1:0] registered_bitmask_b;
    
    //----------------------------------------------------------------
    // FSM States
    //----------------------------------------------------------------
    localparam IDLE = 2'd0;
    localparam PRIORITY_ENCODE = 2'd1;
    localparam PREFIX_SUM = 2'd2;
    localparam CLEAR_BIT = 2'd3;
    
    reg [1:0] state, next_state;
    
    //----------------------------------------------------------------
    // STAGE 1: Priority Encoder (First Cycle)
    //----------------------------------------------------------------
    reg [$clog2(BITMASK_WIDTH)-1:0] lowest_one_position_reg;
    
    // Priority encoder for finding lowest '1' position
    function [$clog2(BITMASK_WIDTH)-1:0] find_lowest_one;
        input [BITMASK_WIDTH-1:0] bit_vector;
        integer j;
        begin
            find_lowest_one = {$clog2(BITMASK_WIDTH){1'b1}}; // Default to all 1's if no bit is set
            for (j = 0; j < BITMASK_WIDTH; j = j + 1) begin
                if (bit_vector[j] && (find_lowest_one == {$clog2(BITMASK_WIDTH){1'b1}})) begin
                    find_lowest_one = j[$clog2(BITMASK_WIDTH)-1:0];
                end
            end
        end
    endfunction
    
    //----------------------------------------------------------------
    // STAGE 2: Prefix Sum Calculation (Second Cycle)
    //----------------------------------------------------------------
    
    // Instantiate the parallel prefix sum module
    wire [$clog2(BITMASK_WIDTH):0] prefix_sum_result;
    
    ParallelPrefixSum #(
        .WIDTH(BITMASK_WIDTH)
    ) prefix_sum_inst (
        .bit_array(registered_bitmask_b),
        .position(lowest_one_position_reg > 0 ? lowest_one_position_reg - 1 : 0),  // Subtract 1 if not at position 0
        .prefix_sum(prefix_sum_result)
    );
    
    //----------------------------------------------------------------
    // Offset Calculation and Weight Selection (Combinational)
    //----------------------------------------------------------------
    reg [$clog2(BITMASK_WIDTH):0] ones_before_position;
    reg [$clog2(BITMASK_WIDTH)-1:0] calculated_offset;
    reg [WEIGHT_WIDTH-1:0] selected_weight;
    
    always @(*) begin
        // If position is 0, offset is 0
        // Otherwise, it's the prefix sum at position-1
        if (lowest_one_position_reg == 0) begin
            ones_before_position = 0;
        end
        else begin
            ones_before_position = prefix_sum_result;
        end
        
        calculated_offset = ones_before_position[$clog2(BITMASK_WIDTH)-1:0];
        selected_weight = fibre_b_data[calculated_offset];
    end
    
    //----------------------------------------------------------------
    // State Machine: Sequential Logic
    //----------------------------------------------------------------
    
    // State register
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
        end
        else begin
            state <= next_state;
        end
    end
    
    // Next state logic
    always @(*) begin
        next_state = state;  // Default: stay in current state
        
        case (state)
            IDLE: begin
                if (valid_match) begin
                    next_state = PRIORITY_ENCODE;
                end
            end
            
            PRIORITY_ENCODE: begin
                if (current_and_result != 0) begin
                    next_state = PREFIX_SUM;
                end
                else begin
                    next_state = IDLE;
                end
            end
            
            PREFIX_SUM: begin
                next_state = CLEAR_BIT;
            end
            
            CLEAR_BIT: begin
                next_state = PRIORITY_ENCODE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Output and datapath logic
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            current_and_result <= 0;
            registered_bitmask_b <= 0;
            lowest_one_position_reg <= 0;
            fast_offset <= 0;
            matched_position <= 0;
            matched_weight <= 0;
            fast_valid <= 0;
            processing_done <= 1;
        end
        else begin
            // Default values
            fast_valid <= 0;
            
            case (state)
                IDLE: begin
                    processing_done <= 1;
                    if (valid_match) begin
                        current_and_result <= and_result;
                        registered_bitmask_b <= bitmask_b;
                        processing_done <= 0;
                    end
                end
                
                PRIORITY_ENCODE: begin
                    if (current_and_result != 0) begin
                        // Stage 1: Find the lowest '1' bit position
                        lowest_one_position_reg <= find_lowest_one(current_and_result);
                    end
                    else begin
                        processing_done <= 1;
                    end
                end
                
                PREFIX_SUM: begin
                    // Stage 2: Calculate offset and select weight
                    // (Prefix sum calculation is done by the instantiated module)
                    matched_position <= lowest_one_position_reg;
                    fast_offset <= calculated_offset;
                    matched_weight <= selected_weight;
                    fast_valid <= 1;
                end
                
                CLEAR_BIT: begin
                    // Clear the processed bit for next iteration
                    current_and_result <= current_and_result & ~(1'b1 << lowest_one_position_reg);
                end
                
                default: begin
                    // Should never reach here
                end
            endcase
        end
    end
    
endmodule

//----------------------------------------------------------------
// Parallel Prefix Sum Module
//----------------------------------------------------------------
module ParallelPrefixSum #(
    parameter WIDTH = 128
)(
    input wire [WIDTH-1:0] bit_array,
    input wire [$clog2(WIDTH)-1:0] position,  // Position to get prefix sum for
    output wire [$clog2(WIDTH):0] prefix_sum  // Prefix sum at the requested position
);
    // First stage: Initialize with the bit values (0 or 1)
    wire [$clog2(WIDTH):0] stage0 [WIDTH-1:0];
    
    // Parameters for log2 calculation must be a constant at compile time
    localparam LOG2_WIDTH = $clog2(WIDTH);
    
    // Intermediate stages for parallel prefix sum calculation
    wire [$clog2(WIDTH):0] stages [0:LOG2_WIDTH][WIDTH-1:0];
    
    genvar i, j, k;
    
    // Stage 0: Initialize with the bit values (0 or 1)
    generate
        for (i = 0; i < WIDTH; i = i + 1) begin: stage0_gen
            assign stage0[i] = bit_array[i] ? 1 : 0;
        end
    endgenerate
    
    generate
        // Copy stage0 to the first stage of the computation
        for (i = 0; i < WIDTH; i = i + 1) begin: stage0_copy
            assign stages[0][i] = stage0[i];
        end
        
        // Build each subsequent stage using a parallel prefix algorithm
        for (j = 1; j <= LOG2_WIDTH; j = j + 1) begin: stages_gen
            for (k = 0; k < WIDTH; k = k + 1) begin: each_element
                if (k >= (1 << (j-1))) begin
                    // Add previous element's value that's 2^(j-1) positions away
                    assign stages[j][k] = stages[j-1][k] + stages[j-1][k - (1 << (j-1))];
                end else begin
                    // Keep the same value for elements that don't have enough preceding elements
                    assign stages[j][k] = stages[j-1][k];
                end
            end
        end
    endgenerate
    
    // Output the prefix sum at the requested position
    assign prefix_sum = stages[LOG2_WIDTH][position];
endmodule