(** Toplevel. *)

open Context

(** Should the interactive shell be run? *)
let interactive_shell = ref true

(** The command-line wrappers that we look for. *)
let wrapper = ref (Some ["rlwrap"; "ledit"])

(** The usage message. *)
let usage = "Usage: lambda [option] ... [file] ..."

let eager = ref false

let deep = ref false

(** The help text printed when [#help] is used. *)
let help_text = "Toplevel directives:
<expr> ;                      evaluate <expr>
#lazy ;                       evaluate lazily (do not evaluate arguments)
#eager ;                      evaluate eagrly (evaluate arguments immediately)
#deep ;                       evaluate inside λ-abstraction
#shallow ;                    do not evaluate inside λ-abstraction
#constant x ... y ;           declare constants
#context ;                    print current definitions
#help ;                       print this help
#quit ;                       exit

Syntax:
^ x ... y . e                  λ-abstraction
e1 e2                          application
"

(** A list of files to be loaded and run. *)
let files = ref []

(** Add a file to the list of files to be loaded, and record whether it should
    be processed in interactive mode. *)
let add_file interactive filename = (files := (filename, interactive) :: !files)

(** A list of command-line wrappers to look for. *)
let wrapper = ref (Some ["rlwrap"; "ledit"])

(** Command-line options *)
let options = Arg.align [
  ("--wrapper",
    Arg.String (fun str -> wrapper := Some [str]),
    "<program> Specify a command-line wrapper to be used (such as rlwrap or ledit)");
  ("--no-wrapper",
    Arg.Unit (fun () -> wrapper := None),
    " Do not use a command-line wrapper");
  ("-v",
    Arg.Unit (fun () ->
      print_endline ("lambda " ^ Version.version ^ "(" ^ Sys.os_type ^ ")");
      exit 0),
    " Print version information and exit");
  ("-V",
   Arg.Int (fun k -> Print.verbosity := k),
   "<int> Set verbosity level");
  ("-n",
    Arg.Clear interactive_shell,
    " Do not run the interactive toplevel");
  ("-l",
    Arg.String (fun str -> add_file false str),
    "<file> Load <file> into the initial environment");
]

(** Treat anonymous arguments as files to be run. *)
let anonymous str =
  add_file true str;
  interactive_shell := false

(** Parser wrapper that reads extra lines on demand. *)
let parse parser lex =
  try
    parser Lexer.token lex
  with
  | Parser.Error ->
      Error.syntax ~loc:(Lexer.position_of_lex lex) ""
  | Failure "lexing: empty token" ->
      Error.syntax ~loc:(Lexer.position_of_lex lex) "unrecognised symbol."

(** [exec_cmd ctx d] executes toplevel directive [d] in context [ctx]. It prints the
    result if in interactive mode, and returns the new context. *)
let rec exec_cmd interactive ctx (d, loc) =
  match d with
    | Input.Expr e ->
      let e = Desugar.expr ctx.names e in
      let e = Norm.norm ~eager:!eager ~deep:!deep ctx.decls e in
        if interactive then Format.printf "    = %t@." (Print.expr ctx.names e) ;
        ctx
    | Input.Context ->
      ignore
        (List.fold_right
           (fun x k ->
             (match Context.lookup_definition k ctx with
               | None ->
                 Format.printf "#constant @[%s@];@." x
               | Some e ->
                 Format.printf "@[%s := %t@];@." x (Print.expr ctx.names e)) ;
             k - 1)
           ctx.names (List.length ctx.names - 1)) ;
      ctx
    | Input.Eager b ->
      eager := b ;
      Format.printf "@[I will evaluate %s.@." (if !eager then "eagerly" else "lazily") ;
      ctx
    | Input.Deep b ->
      deep := b ;
      Format.printf "@[I will evaluate %s.@." (if !deep then "deeply" else "shallowly") ;
      ctx
    | Input.TopConstant xs ->
      List.fold_left
        (fun ctx x ->
          if List.mem x ctx.names then Error.typing ~loc "%s already exists" x ;
          if interactive then Format.printf "%s is a constant.@." x ;
          add_parameter x ctx)
        ctx xs
    | Input.TopDefine (x, e) ->
      if List.mem x ctx.names then Error.typing ~loc "%s already exists" x ;
      let e = Desugar.expr ctx.names e in
        if interactive then
          Format.printf "%s is defined.@." x ;
        add_definition x e ctx
    | Input.Help ->
      print_endline help_text ; ctx
    | Input.Quit -> exit 0

(** Load directives from the given file. *)
and use_file ctx (filename, interactive) =
  let cmds = Lexer.read_file (parse Parser.file) filename in
    List.fold_left (exec_cmd interactive) ctx cmds

(** Interactive toplevel *)
let toplevel ctx =
  let eof = match Sys.os_type with
    | "Unix" | "Cygwin" -> "Ctrl-D"
    | "Win32" -> "Ctrl-Z"
    | _ -> "EOF"
  in
  print_endline ("lambda " ^ Version.version);
  print_endline ("[Type " ^ eof ^ " to exit or \"#help;\" for help.]");
  try
    let ctx = ref ctx in
    while true do
      try
        let cmd = Lexer.read_toplevel (parse Parser.commandline) () in
        ctx := exec_cmd true !ctx cmd
      with
        | Error.Error err -> Print.error err
        | Sys.Break -> prerr_endline "Interrupted."
    done
  with End_of_file -> ()

(** Main program *)
let main =
  Sys.catch_break true;
  (* Parse the arguments. *)
  Arg.parse options anonymous usage;
  (* Attempt to wrap yourself with a line-editing wrapper. *)
  if !interactive_shell then
    begin match !wrapper with
      | None -> ()
      | Some lst ->
          let n = Array.length Sys.argv + 2 in
          let args = Array.make n "" in
            Array.blit Sys.argv 0 args 1 (n - 2);
            args.(n - 1) <- "--no-wrapper";
            List.iter
              (fun wrapper ->
                 try
                   args.(0) <- wrapper;
                   Unix.execvp wrapper args
                 with Unix.Unix_error _ -> ())
              lst
    end;
  (* Files were listed in the wrong order, so we reverse them *)
  files := List.rev !files;
  (* Set the maximum depth of pretty-printing, after which it prints ellipsis. *)
  Format.set_max_boxes 42 ;
  Format.set_ellipsis_text "..." ;
  try
    (* Run and load all the specified files. *)
    let ctx = List.fold_left use_file empty_context !files in
    if !interactive_shell then toplevel ctx
  with
    Error.Error err -> Print.error err; exit 1