{ ... }:
let
  ollama-model-name = "llama3-groq-tool-use:8b";
  model-id = "home-ollama";
  max-context = 8192;
  max-chat-tokens = 8192;
  max-generate-tokens = 8192;
in
{
  command = "lsp-ai";

  config = {
    memory = {
      file_store = { };
      # vector_store = {
      #   embedding_model = {
      #     type = "ollama";
      #     model = "nomic-embed-text";
      #     prefix = {
      #       retrieval = "search_query";
      #       storage = "search_document";
      #     };
      #   };
      #   splitter = {
      #     type = "tree_sitter";
      #   };
      #   data_type = "f32";
      # };
    };
    models = {
      home-ollama = {
        type = "ollama";
        model = ollama-model-name;
        chat_endpoint = "http://smortress:11434/api/chat";
        generate_endpoint = "http://smortress:11434/api/generate";
      };
    };

    chat = [
      {
        trigger = "!C";
        action_display_name = "Chat";
        model = model-id;
        parameters = {
          max_context = max-context;
          max_tokens = max-chat-tokens;
          system = ''
            You are a code assistant chatbot. The user will ask you for assistance coding and you will do you best to answer succinctly and accurately
          '';
        };
      }
      {
        trigger = "!CC";
        action_display_name = "Chat with context";
        model = model-id;
        parameters = {
          max_context = max-context;
          max_tokens = max-chat-tokens;
          system = ''
            You are a code assistant chatbot. The user will ask you for assistance coding and you will do you best to answer succinctly and accurately given the code context:

            {CONTEXT}
          '';
        };
      }
    ];

    actions = [
      {
        action_display_name = "Complete";
        model = model-id;
        parameters = {
          max_context = max-context;
          max_tokens = max-generate-tokens;
          system = ''
            You are an AI coding assistant. Your task is to complete code snippets. The user's cursor position is marked by "<CURSOR>". Follow these steps:
            1. Analyze the code context and the cursor position.
            2. Provide your chain of thought reasoning, wrapped in <reasoning> tags. Include thoughts about the cursor position, what needs to be completed, and any necessary formatting.
            3. Determine the appropriate code to complete the current thought, including finishing partial words or lines.
            4. Replace "<CURSOR>" with the necessary code, ensuring proper formatting and line breaks.
            5. Wrap your code solution in <answer> tags.
            Your response should always include both the reasoning and the answer. Pay special attention to completing partial words or lines before adding new lines of code.

            <examples>

            <example>
            User input:
            --main.py--
            # A function that reads in user inpu<CURSOR>

            Response:
            <reasoning>
            1. The cursor is positioned after "inpu" in a comment describing a function that reads user input.
            2. We need to complete the word "input" in the comment first.
            3. After completing the comment, we should add a new line before defining the function.
            4. The function should use Python's built-in `input()` function to read user input.
            5. We'll name the function descriptively and include a return statement.
            </reasoning>
            <answer>t
            def read_user_input():
                user_input = input("Enter your input: ")
                return user_input
            </answer>

            </example>

            <example>
            User input:
            --main.py--
            def fibonacci(n):
                if n <= 1:
                    return n
                else:
                    re<CURSOR>

            Response:
            <reasoning>
            1. The cursor is positioned after "re" in the 'else' clause of a recursive Fibonacci function.
            2. We need to complete the return statement for the recursive case.
            3. The "re" already present likely stands for "return", so we'll continue from there.
            4. The Fibonacci sequence is the sum of the two preceding numbers.
            5. We should return the sum of fibonacci(n-1) and fibonacci(n-2).
            </reasoning>
            <answer>turn fibonacci(n-1) + fibonacci(n-2)</answer>

            </example>

            </examples>
          '';
          messages = [
            {
              role = "user";
              content = "{CODE}";
            }
          ];
        };
        post_process = {
          extractor = "(?s)<answer>(.*?)</answer>";
        };
      }
      {
        action_display_name = "Refactor";
        model = model-id;
        parameters = {
          max_context = max-context;
          max_tokens = max-generate-tokens;
          system = ''
            You are an AI coding assistant specializing in code refactoring. Your task is to analyze the given code snippet and provide a refactored version. Follow these steps:
            1. Analyze the code context and structure.
            2. Identify areas for improvement, such as code efficiency, readability, or adherence to best practices.
            3. Provide your chain of thought reasoning, wrapped in <reasoning> tags. Include your analysis of the current code and explain your refactoring decisions.
            4. Rewrite the entire code snippet with your refactoring applied.
            5. Wrap your refactored code solution in <answer> tags.
            Your response should always include both the reasoning and the refactored code.

            <examples>

            <example>
            User input:
            def calculate_total(items):
                total = 0
                for item in items:
                    total = total + item['price'] * item['quantity']
                return total

            Response:
            <reasoning>
            1. The function calculates the total cost of items based on price and quantity.
            2. We can improve readability and efficiency by:
               a. Using a more descriptive variable name for the total.
               b. Utilizing the sum() function with a generator expression.
               c. Using augmented assignment (+=) if we keep the for loop.
            3. We'll implement the sum() function approach for conciseness.
            4. We'll add a type hint for better code documentation.
            </reasoning>
            <answer>
            from typing import List, Dict
            def calculate_total(items: List[Dict[str, float]]) -> float:
                return sum(item['price'] * item['quantity'] for item in items)
            </answer>

            </example>

            <example>
            User input:
            def is_prime(n):
                if n < 2:
                    return False
                for i in range(2, n):
                    if n % i == 0:
                        return False
                return True

            Response:
            <reasoning>
            1. This function checks if a number is prime, but it's not efficient for large numbers.
            2. We can improve it by:
               a. Adding an early return for 2, the only even prime number.
               b. Checking only odd numbers up to the square root of n.
               c. Using a more efficient range (start at 3, step by 2).
            3. We'll also add a type hint for better documentation.
            4. The refactored version will be more efficient for larger numbers.
            </reasoning>
            <answer>
            import math
            def is_prime(n: int) -> bool:
                if n < 2:
                    return False
                if n == 2:
                    return True
                if n % 2 == 0:
                    return False

                for i in range(3, int(math.sqrt(n)) + 1, 2):
                    if n % i == 0:
                        return False
                return True
            </answer>

            </example>

            </examples>
          '';
          messages = [
            {
              role = "user";
              content = "{SELECTED_TEXT}";
            }
          ];
        };
        post_process = {
          extractor = "(?s)<answer>(.*?)</answer>";
        };
      }
    ];

    # completion = {
    #   model = model-id;
    #   parameters = {
    #     max_tokens = max-tokens;
    #     max_context = max-context;

    #     messages = [
    #       {
    #         role = "system";
    #         content = ''
    #           Instructions:
    #           - You are an AI programming assistant.
    #           - Given a piece of code with the cursor location marked by "<CURSOR>", replace "<CURSOR>" with the correct code or comment.
    #           - First, think step-by-step.
    #           - Describe your plan for what to build in pseudocode, written out in great detail.
    #           - Then output the code replacing the "<CURSOR>"
    #           - Ensure that your completion fits within the language context of the provided code snippet (e.g., Go, Ruby, Bash, Java, Puppet DSL).

    #           Rules:
    #           - Only respond with code or comments.
    #           - Only replace "<CURSOR>"; do not include any previously written code.
    #           - Never include "<CURSOR>" in your response
    #           - If the cursor is within a comment, complete the comment meaningfully.
    #           - Handle ambiguous cases by providing the most contextually appropriate completion.
    #           - Be consistent with your responses.
    #         '';
    #       }
    #       {
    #         role = "user";
    #         content = ''
    #           func greet(name) {
    #               print(f\"Hello, {<CURSOR>}\")
    #           }
    #         '';
    #       }
    #       {
    #         role = "assistant";
    #         content = ''
    #           name
    #         '';
    #       }
    #       {
    #         role = "user";
    #         content = ''
    #           func sum(a, b) {
    #               return a + <CURSOR>
    #           }
    #         '';
    #       }
    #       {
    #         role = "assistant";
    #         content = ''
    #           b
    #         '';
    #       }
    #       {
    #         role = "user";
    #         content = ''
    #           func multiply(a, b int) int {
    #               a * <CURSOR>
    #           }
    #         '';
    #       }
    #       {
    #         role = "assistant";
    #         content = ''
    #           b
    #         '';
    #       }
    #       {
    #         role = "user";
    #         content = ''
    #           // <CURSOR>
    #           func add(a, b) {
    #               return a + b
    #           }
    #         '';
    #       }
    #       {
    #         role = "assistant";
    #         content = ''
    #           Adds two numbers
    #         '';
    #       }
    #       {
    #         role = "user";
    #         content = ''
    #           // This function checks if a number is even
    #           <CURSOR>
    #         '';
    #       }
    #       {
    #         role = "assistant";
    #         content = ''
    #           func is_even(n) {
    #               return n % 2 == 0
    #           }
    #         '';
    #       }
    #       {
    #         role = "user";
    #         content = ''
    #           {CODE}
    #         '';
    #       }
    #     ];
    #   };
    # };
  };
}
