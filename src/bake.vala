private bool pretty_print = true;
private bool debug_enabled = false;
private string original_dir;
private static bool directory_changed;

public class BuildModule
{
    public virtual void generate_toplevel_rules (Recipe toplevel)
    {
    }

    public virtual void generate_rules (Recipe recipe)
    {
    }
    
    public virtual bool generate_program_rules (Recipe recipe, string program)
    {
        return false;
    }

    public virtual bool generate_library_rules (Recipe recipe, string library)
    {
        return false;
    }

    public virtual void recipe_complete (Recipe recipe)
    {
    }

    public virtual void rules_complete (Recipe toplevel)
    {
    }
}

public List<string> split_variable (string value)
{
    List<string> values = null;

    var start = 0;
    while (true)
    {
        while (value[start].isspace ())
            start++;
        if (value[start] == '\0')
            return values;

        var end = start + 1;
        while (value[end] != '\0' && !value[end].isspace ())
            end++;

        values.append (value.substring (start, end - start));
        start = end;
    }
}

public string get_relative_path (string source_path, string target_path)
{
    /* Already relative */
    if (!Path.is_absolute (target_path))
        return target_path;
    
    /* It is the current directory */
    if (target_path == source_path)
        return ".";

    var dir = source_path + "/";
    if (target_path.has_prefix (dir))
        return target_path.substring (dir.length);

    var path = source_path;
    var relative_path = Path.get_basename (target_path);
    while (true)
    {
        path = Path.get_dirname (path);
        relative_path = "../" + relative_path;

        if (target_path.has_prefix (path + "/"))
            return relative_path;
    }
}

public string remove_extension (string filename)
{
    var i = filename.last_index_of_char ('.');
    if (i < 0)
        return filename;
    return filename.substring (0, i);
}

public string replace_extension (string filename, string extension)
{
    var i = filename.last_index_of_char ('.');
    if (i < 0)
        return "%s.%s".printf (filename, extension);

    return "%.*s.%s".printf (i, filename, extension);
}

public errordomain BuildError 
{
    INVALID,
    NO_RULE,
    COMMAND_FAILED,
    MISSING_OUTPUT
}

public class Rule
{
    public Recipe recipe;
    public List<string> inputs;
    public List<string> outputs;
    public List<string> commands;

    public Rule (Recipe recipe)
    {
        this.recipe = recipe;
    }
    
    private static int timespec_cmp (Posix.timespec a, Posix.timespec b)
    {
        if (a.tv_sec == b.tv_sec)
            return (int) (a.tv_nsec - b.tv_nsec);
        else
            return (int) (a.tv_sec - b.tv_sec);
    }

    public bool needs_build ()
    {
        /* Find the most recently changed input */
        Posix.timespec max_input_time = { 0, 0 };
        string? youngest_input = null;
        foreach (var input in inputs)
        {
            Stat file_info;
            var e = stat (input, out file_info);
            if (e == 0)
            {
                if (timespec_cmp (file_info.st_mtim, max_input_time) > 0)
                {
                    max_input_time = file_info.st_mtim;
                    youngest_input = input;
                }
            }
            else
            {
                if (errno == Posix.ENOENT)
                {
                    if (debug_enabled)
                        stderr.printf ("Input %s is missing\n", get_relative_path (original_dir, Path.build_filename (recipe.dirname, input)));
                }
                else
                    warning ("Unable to access input file %s: %s", input, strerror (errno));
                /* Something has gone wrong, run the rule anyway and it should fail */
                return true;
            }
        }

        /* Rebuild if any of the outputs are missing */
        Posix.timespec max_output_time = { 0, 0 };
        string? youngest_output = null;
        foreach (var output in outputs)
        {
            /* Always rebuild if doesn't produce output */
            if (output.has_prefix ("%"))
                return true;

            Stat file_info;
            var e = stat (output, out file_info);
            if (e == 0)
            {
                if (timespec_cmp (file_info.st_mtim, max_output_time) > 0)
                {
                    max_output_time = file_info.st_mtim;
                    youngest_output = output;
                }
            }
            else
            {
                if (debug_enabled && errno == Posix.ENOENT)
                    stderr.printf ("Output %s is missing\n", get_relative_path (original_dir, Path.build_filename (recipe.dirname, output)));

                return true;
            }
        }

        if (timespec_cmp (max_input_time, max_output_time) > 0)
        {
            if (debug_enabled)
                stderr.printf ("Rebuilding %s as %s is newer\n",
                               get_relative_path (original_dir, Path.build_filename (recipe.dirname, youngest_output)),
                               get_relative_path (original_dir, Path.build_filename (recipe.dirname, youngest_input)));
            return true;
        }

        return false;
    }

    public void build () throws BuildError
    {
        foreach (var c in commands)
        {
            var show_output = true;
            if (c.has_prefix ("@"))
            {
                c = c.substring (1);
                show_output = !pretty_print;
            }

            c = recipe.substitute_variables (c);

            if (show_output)
                print ("    %s\n", c);

            var exit_status = Posix.system (c);
            if (Process.if_signaled (exit_status))
                throw new BuildError.COMMAND_FAILED ("Build stopped with signal %d", Process.term_sig (exit_status));
            if (Process.if_exited (exit_status) && Process.exit_status (exit_status) != 0)
                throw new BuildError.COMMAND_FAILED ("Build stopped with return value %d", Process.exit_status (exit_status));               
        }

        foreach (var output in outputs)
        {
            if (!output.has_prefix ("%") && !FileUtils.test (output, FileTest.EXISTS))
                throw new BuildError.MISSING_OUTPUT ("Failed to build file %s", output);
        }
    }

    public void add_status_command (string status)
    {
        if (!pretty_print)
            return;

        // FIXME: Escape if necessary
        commands.append ("@echo '    %s'".printf (status));
    }
}

public class Recipe
{
    public string filename;
    public Recipe? parent = null;
    public List<Recipe> children;
    private HashTable<string, string> variables;
    public List<Rule> rules;
    public Rule build_rule;
    public Rule install_rule;
    public Rule clean_rule;
    public Rule test_rule;
    
    public string dirname { owned get { return Path.get_dirname (filename); } }

    public string build_directory { owned get { return Path.build_filename (dirname, ".built"); } }

    public string install_directory
    {
        owned get
        {
            var dir = get_variable ("install-directory");
            if (dir == null || Path.is_absolute (dir))
                return dir;
            return Path.build_filename (original_dir, dir);
        }
    }

    public string source_directory { owned get { return get_variable ("source-directory"); } }
    public string top_source_directory { owned get { return get_variable ("top-source-directory"); } }
    public string binary_directory { owned get { return get_variable ("binary-directory"); } }
    public string system_binary_directory { owned get { return get_variable ("system-binary-directory"); } }
    public string library_directory { owned get { return get_variable ("library-directory"); } }
    public string system_library_directory { owned get { return get_variable ("system-library-directory"); } }
    public string data_directory { owned get { return get_variable ("data-directory"); } }
    public string include_directory { owned get { return get_variable ("include-directory"); } }
    public string package_data_directory { owned get { return get_variable ("package-data-directory"); } }

    public string package_name { owned get { return get_variable ("package|name"); } }
    public string package_version { owned get { return get_variable ("package|version"); } }
    public string release_name
    {
        owned get
        {
            if (package_version == null)
                return package_name;
            else
                return "%s-%s".printf (package_name, package_version);
        }
    }

    public Recipe (string filename, bool allow_rules = true) throws FileError, BuildError
    {
        this.filename = filename;

        variables = new HashTable<string, string> (str_hash, str_equal);

        string contents;
        FileUtils.get_contents (filename, out contents);
        parse (filename, contents, allow_rules);

        var build_dir_rule = add_rule ();
        build_dir_rule.outputs.append (".built/");
        build_dir_rule.commands.append ("@mkdir .built");

        build_rule = find_rule ("%build");
        if (build_rule == null)
        {
            build_rule = add_rule ();
            build_rule.inputs.prepend (".built/");
            build_rule.outputs.append ("%build");
        }

        install_rule = find_rule ("%install");
        if (install_rule == null)
        {
            install_rule = add_rule ();
            install_rule.outputs.append ("%install");
        }

        clean_rule = find_rule ("%clean");
        if (clean_rule == null)
        {
            clean_rule = add_rule ();
            clean_rule.outputs.append ("%clean");
        }

        test_rule = find_rule ("%test");
        if (test_rule == null)
        {
            test_rule = add_rule ();
            test_rule.outputs.append ("%test");
        }
    }

    public string? get_variable (string name)
    {
        var value = variables.lookup (name);
        if (value == null && parent != null)
            return parent.get_variable (name);
        else
           return value;
    }

    public List<string> get_variable_children (string name)
    {
        var children = new List<string> ();
        var prefix = name + "|";
        foreach (var variable_name in variables.get_keys ())
        {
            if (!variable_name.has_prefix (prefix))
                continue;

            var length = 0;
            while (variable_name[prefix.length + 1 + length] != '|' && variable_name[prefix.length + 1 + length] != '\0')
                length++;
            var child_name = variable_name.substring (prefix.length, length + 1);
            if (has_value (children, child_name))
                continue;

            children.append (child_name);
        }

        return children;
    }

    private bool has_value (List<string> list, string value)
    {
        foreach (var v in list)
            if (v == value)
                return true;
        return false;
    }

    public void set_variable (string name, string value)
    {
        variables.insert (name, value);
    }

    private void parse (string filename, string contents, bool allow_rules) throws BuildError
    {
        var lines = contents.split ("\n");
        var line_number = 0;
        var in_rule = false;
        string? rule_indent = null;
        var continued_line = "";
        foreach (var line in lines)
        {
            line_number++;
            
            line = line.chomp ();
            if (line.has_suffix ("\\"))
            {
                continued_line += line.substring (0, line.length - 1) + "\n";
                continue;
            }

            line = continued_line + line;
            continued_line = "";

            var i = 0;
            while (line[i].isspace ())
                i++;
            var indent = line.substring (0, i);
            var statement = line.substring (i);

            if (in_rule)
            {
                if (rule_indent == null)
                    rule_indent = indent;

                if (indent == rule_indent && statement != "")
                {
                    var rule = rules.last ().data;
                    rule.commands.append (statement);
                    continue;
                }
                in_rule = false;
                rule_indent = null;
            }

            if (statement == "")
                continue;
            if (statement.has_prefix ("#"))
                continue;

            /* Load variables */
            var index = statement.index_of ("=");
            if (index > 0)
            {
                var name = statement.substring (0, index).strip ();
                variables.insert (name, statement.substring (index + 1).strip ());
                continue;
            }

            /* Load explicit rules */
            index = statement.index_of (":");
            if (index > 0 && allow_rules)
            {
                var rule = add_rule ();

                var input_list = statement.substring (0, index).chomp ();
                foreach (var output in split_variable (input_list))
                    rule.outputs.append (output);

                var output_list = statement.substring (index + 1).strip ();
                foreach (var input in split_variable (output_list))
                    rule.inputs.append (input);

                in_rule = true;
                continue;
            }

            throw new BuildError.INVALID ("Invalid statement in file %s line %d:\n%s", get_relative_path (original_dir, filename), line_number, line);
        }
    }
    
    public Rule add_rule ()
    {
        var rule = new Rule (this);
        rules.append (rule);
        return rule;
    }

    public string substitute_variables (string line)
    {
        var new_line = line;
        while (true)
        {
            var start = new_line.index_of ("$(");
            if (start < 0)
                break;
            var end = new_line.index_of (")", start);
            if (end < 0)
                break;

            var prefix = new_line.substring (0, start);
            var variable = new_line.substring (start + 2, end - start - 2);
            var suffix = new_line.substring (end + 1);

            var value = get_variable (variable);
            if (value == null)
                value = "";
            
            new_line = prefix + value + suffix;
        }

        return new_line;
    }

    public string get_build_path (string path, bool important = false)
    {
        if (important)
            return path;
        else
            return get_relative_path (dirname, Path.build_filename (build_directory, path));
    }

    public string get_install_path (string path)
    {
        if (install_directory == null || install_directory == "")
            return path;
        else
            return "%s%s".printf (install_directory, path);
    }

    public void add_install_rule (string filename, string install_dir, string? target_filename = null)
    {
        install_rule.inputs.append (filename);
        if (target_filename == null)
            target_filename = filename;
        var install_path = get_install_path (Path.build_filename (install_dir, target_filename));
        install_rule.commands.append ("@mkdir -p %s".printf (Path.get_dirname (install_path)));
        install_rule.commands.append ("@install %s %s".printf (filename, install_path));
    }

    public void generate_clean_rule ()
    {
        foreach (var rule in rules)
        {
            foreach (var output in rule.outputs)
            {
                /* Ignore virtual outputs */
                if (output.has_prefix ("%"))
                    continue;

                if (output.has_suffix ("/"))
                {
                    /* Don't accidentally delete someone's entire hard-disk */
                    if (output.has_prefix ("/"))
                        warning ("Not making clean rule for absolute directory %s", output);
                    else
                    {
                        clean_rule.add_status_command ("RM %s".printf (output));
                        clean_rule.commands.append ("@rm -rf %s".printf (output));
                    }
                }
                else
                {
                    var build_dir = get_relative_path (dirname, build_directory);

                    if (!output.has_prefix (build_dir + "/"))
                    {
                        clean_rule.add_status_command ("RM %s".printf (output));
                        clean_rule.commands.append ("@rm -f %s".printf (output));
                    }
                }
            }
        }
    }
    
    public Recipe toplevel
    {
        get { if (parent.parent == null) return this; else return parent.toplevel; }
    }

    public string relative_dirname
    {
        owned get { return get_relative_path (toplevel.dirname, dirname); }
    }

    public Rule? find_rule (string output)
    {
        foreach (var rule in rules)
        {
            foreach (var o in rule.outputs)
            {
                if (o == output)
                    return rule;
            }
        }

        return null;
    }
    
    public Rule? find_rule_recursive (string output)
    {
        var rule = find_rule (output);
        if (rule != null)
            return rule;

        foreach (var child in children)
        {
            rule = child.find_rule_recursive (output);
            if (rule != null)
                return rule;
        }

        return null;
    }

    /* Find the recipe that builds this target or null if no recipe builds it */
    public Recipe? get_recipe_with_target (string target)
    {
        /* See if we have a rule */
        foreach (var rule in rules)
        {
            foreach (var output in rule.outputs)
                if (output == target)
                    return this;
        }

        /* Could be in a parent recipe... */
        if (target.has_prefix ("../"))
        {
            if (parent == null)
                return null;
            return parent.get_recipe_with_target (target.substring (3));
        }

        /* ...or a child recipe */
        foreach (var child in children)
        {
            var child_dir = "%s/".printf (get_relative_path (dirname, child.dirname));
            if (target.has_prefix (child_dir) && target != child_dir)
                return child.get_recipe_with_target (target.substring (child_dir.length));
        }

        /* There's no rule to build this */
        return null;
    }

    private void change_directory (string dirname)
    {
        if (Environment.get_current_dir () == dirname)
            return;

        directory_changed = true;
        Environment.set_current_dir (dirname);
    }

    private void log_directory_change ()
    {
        if (directory_changed)
            GLib.print ("\x1B[1m[Entering directory %s]\x1B[0m\n", get_relative_path (original_dir, Environment.get_current_dir ()));
        directory_changed = false;
    }
    
    public void build_target (string target) throws BuildError
    {
        if (debug_enabled)
            stderr.printf ("Considering target %s\n", get_relative_path (original_dir, Path.build_filename (dirname, target)));

        /* If the rule comes from another recipe, use it to build */
        var recipe = get_recipe_with_target (target);
        if (recipe != null && recipe != this)
        {
            if (debug_enabled)
                stderr.printf ("Target %s defined in recipe %s\n",
                               get_relative_path (original_dir, Path.build_filename (dirname, target)),
                               get_relative_path (original_dir, recipe.filename));
            recipe.build_target (Path.get_basename (target));
            return;
        }

        /* Find a for this target */
        var rule = find_rule (target);
        if (rule == null)
            rule = find_rule ("%" + target);
        if (rule == null)
        {
            /* If it's already there then don't need to do anything */
            var path = Path.build_filename (dirname, target);
            if (FileUtils.test (path, FileTest.EXISTS))
                return;

            /* If doesn't exist then we can't continue */
            throw new BuildError.NO_RULE ("No rule to build '%s'", get_relative_path (original_dir, target));
        }

        /* Check the inputs first */
        foreach (var input in rule.inputs)
            build_target (input);

        /* Don't bother if it's already up to date */
        change_directory (dirname);
        if (!rule.needs_build ())
            return;

        /* If we're about to do something then note which directory we are in and what we're building */
        if (rule.commands != null)
            log_directory_change ();

        /* Run the commands */
        rule.build ();
    }

    public void print ()
    {
        foreach (var name in variables.get_keys ())
            stdout.printf ("%s=%s\n", name, get_variable (name));
        foreach (var rule in rules)
        {
            stdout.printf ("\n");
            foreach (var output in rule.outputs)
                stdout.printf ("%s ", output);
            stdout.printf (":");
            foreach (var input in rule.inputs)
                stdout.printf (" %s", input);
            stdout.printf ("\n");
            foreach (var c in rule.commands)
                stdout.printf ("    %s\n", c);
        }
    }
}

public class Bake
{
    private static bool show_version = false;
    private static bool show_verbose = false;
    private static bool do_configure = false;
    private static bool do_unconfigure = false;
    private static bool do_expand = false;
    private static const OptionEntry[] options =
    {
        { "configure", 0, 0, OptionArg.NONE, ref do_configure,
          /* Help string for command line --configure flag */
          N_("Configure build options"), null},
        { "unconfigure", 0, 0, OptionArg.NONE, ref do_unconfigure,
          /* Help string for command line --unconfigure flag */
          N_("Clear configuration"), null},
        { "expand", 0, 0, OptionArg.NONE, ref do_expand,
          /* Help string for command line --expand flag */
          N_("Expand current recipe and print to stdout"), null},
        { "version", 'v', 0, OptionArg.NONE, ref show_version,
          /* Help string for command line --version flag */
          N_("Show release version"), null},
        { "verbose", 0, 0, OptionArg.NONE, ref show_verbose,
          /* Help string for command line --verbose flag */
          N_("Show verbose output"), null},
        { "debug", 'd', 0, OptionArg.NONE, ref debug_enabled,
          /* Help string for command line --debug flag */
          N_("Print debugging messages"), null},
        { null }
    };

    public static List<BuildModule> modules;

    public static Recipe? load_recipes (string filename, bool is_toplevel = true) throws Error
    {
        if (debug_enabled)
            stderr.printf ("Loading %s\n", get_relative_path (original_dir, filename));

        var f = new Recipe (filename);

        /* Children can't be new toplevel recipes */
        if (!is_toplevel && f.package_name != null)
        {
            if (debug_enabled)
                stderr.printf ("Ignoring toplevel recipe %s\n", filename);
            return null;
        }

        /* Load children */
        var dir = Dir.open (f.dirname);
        while (true)
        {
            var child_dir = dir.read_name ();
            if (child_dir == null)
                 break;

            var child_filename = Path.build_filename (f.dirname, child_dir, "Recipe");
            if (FileUtils.test (child_filename, FileTest.EXISTS))
            {
                var c = load_recipes (child_filename, false);
                if (c != null)
                {
                    c.parent = f;
                    f.children.append (c);
                }
            }
        }
        
        /* Make rules recurse */
        foreach (var c in f.children)
        {
            f.build_rule.inputs.append ("%s/%%build".printf (Path.get_basename (c.dirname)));
            f.install_rule.inputs.append ("%s/%%install".printf (Path.get_basename (c.dirname)));
            f.clean_rule.inputs.append ("%s/%%clean".printf (Path.get_basename (c.dirname)));
            f.test_rule.inputs.append ("%s/%%test".printf (Path.get_basename (c.dirname)));
        }

        return f;
    }

    public static void recipe_complete (Recipe recipe)
    {
        foreach (var module in modules)
            module.recipe_complete (recipe);

        foreach (var child in recipe.children)
            recipe_complete (child);
    }

    private static bool generate_library_rules (Recipe recipe)
    {
        var libraries = recipe.get_variable_children ("libraries");
        foreach (var library in libraries)
        {
            var matched = false;
            foreach (var module in modules)
            {
                if (module.generate_library_rules (recipe, library))
                {
                    matched = true;
                    break;
                }
            }

            if (!matched)
            {
                printerr ("Unable to generate rules for library %s in file %s\n", library, get_relative_path (original_dir, recipe.filename));
                return false;
            }
        }

        /* Traverse the recipe tree */
        foreach (var child in recipe.children)
        {
            if (!generate_library_rules (child))
                return false;
        }

        return true;
    }

    private static bool generate_program_rules (Recipe recipe)
    {
        var programs = recipe.get_variable_children ("programs");
        foreach (var program in programs)
        {
            var matched = false;
            foreach (var module in modules)
            {
                if (module.generate_program_rules (recipe, program))
                {
                    matched = true;
                    break;
                }
            }
            if (!matched)
            {
                printerr ("Unable to generate rules for program %s in file %s\n", program, get_relative_path (original_dir, recipe.filename));
                return false;
            }
        }

        /* Traverse the recipe tree */
        foreach (var child in recipe.children)
        {
            if (!generate_program_rules (child))
                return false;
        }

        return true;
    }

    private static bool generate_rules (Recipe recipe)
    {
        foreach (var module in modules)
            module.generate_rules (recipe);

        /* Traverse the recipe tree */
        foreach (var child in recipe.children)
        {
            if (!generate_rules (child))
                return false;
        }

        return true;
    }

    private static void generate_clean_rules (Recipe recipe)
    {
        recipe.generate_clean_rule ();
        foreach (var child in recipe.children)
            generate_clean_rules (child);
    }

    public static int main (string[] args)
    {
        original_dir = Environment.get_current_dir ();

        var context = new OptionContext (/* Arguments and description for --help text */
                                         _("[TARGET] - Build system"));
        context.add_main_entries (options, Config.GETTEXT_PACKAGE);
        try
        {
            context.parse (ref args);
        }
        catch (Error e)
        {
            stderr.printf ("%s\n", e.message);
            stderr.printf (/* Text printed out when an unknown command-line argument provided */
                           _("Run '%s --help' to see a full list of available command line options."), args[0]);
            stderr.printf ("\n");
            return Posix.EXIT_FAILURE;
        }
        if (show_version)
        {
            /* Note, not translated so can be easily parsed */
            stderr.printf ("bake %s\n", Config.VERSION);
            return Posix.EXIT_SUCCESS;
        }

        pretty_print = !show_verbose;

        modules.append (new BZIPModule ());
        modules.append (new BZRModule ());
        modules.append (new DataModule ());
        modules.append (new DesktopModule ());
        modules.append (new DpkgModule ());
        modules.append (new GCCModule ());
        modules.append (new GettextModule ());
        modules.append (new GHCModule ());
        modules.append (new GITModule ());
        modules.append (new GNOMEModule ());
        modules.append (new GSettingsModule ());
        modules.append (new GZIPModule ());
        modules.append (new JavaModule ());
        modules.append (new LaunchpadModule ());
        modules.append (new MallardModule ());
        modules.append (new ManModule ());
        modules.append (new MonoModule ());
        modules.append (new PythonModule ());
        modules.append (new ReleaseModule ());
        modules.append (new RPMModule ());
        modules.append (new TestModule ());
        modules.append (new ValaModule ());
        modules.append (new XZIPModule ());

        /* Find the toplevel */
        var toplevel_dir = Environment.get_current_dir ();
        var is_toplevel = true;
        Recipe? toplevel = null;
        while (true)
        {
            try
            {
                toplevel = new Recipe (Path.build_filename (toplevel_dir, "Recipe"));
                if (toplevel.package_name != null)
                    break;
            }
            catch (Error e)
            {
                if (e is FileError.NOENT)
                    printerr ("Unable to find toplevel recipe\n");
                else
                    printerr ("Unable to build: %s\n", e.message);
                return Posix.EXIT_FAILURE;
            }
            is_toplevel = false;
            toplevel_dir = Path.get_dirname (toplevel_dir);
        }

        if (do_unconfigure)
        {
            FileUtils.unlink (Path.build_filename (toplevel_dir, "Recipe.conf"));
            return Posix.EXIT_SUCCESS;
        }

        /* Load configuration */
        var need_configure = false;
        Recipe conf_file = null;
        try
        {
            conf_file = new Recipe (Path.build_filename (toplevel_dir, "Recipe.conf"), false);
        }
        catch (Error e)
        {
            if (e is FileError.NOENT)
                need_configure = true;
            else
            {
                printerr ("Failed to load configuration: %s\n", e.message);
                return Posix.EXIT_FAILURE;
            }
        }

        if (do_configure || need_configure)
        {
            var conf_variables = new HashTable<string, string> (str_hash, str_equal);

            /* Default values */
            conf_variables.insert ("resource-directory", "/usr/local");
            conf_variables.insert ("system-config-directory", "/etc");
            conf_variables.insert ("system-binary-directory", "/sbin");
            conf_variables.insert ("system-library-directory", "/lib");

            /* Load args from the command line */
            if (do_configure)
            {
                for (var i = 1; i < args.length; i++)
                {
                    var arg = args[i];
                    var index = arg.index_of ("=");
                    var name = "", value = "";
                    if (index >= 0)
                    {
                        name = arg.substring (0, index).strip ();
                        value = arg.substring (index + 1).strip ();
                    }
                    if (name == "" || value == "")
                    {
                        stderr.printf ("Invalid configure argument '%s'.  Arguments should be in the form name=value\n", arg);
                        return Posix.EXIT_FAILURE;
                    }
                    conf_variables.insert (name, value);
                }
            }

            GLib.print ("\x1B[1m[Configuring]\x1B[0m\n");

            /* Make directories absolute */
            // FIXME
            //if (install_directory != null && !Path.is_absolute (install_directory))
            //    install_directory = Path.build_filename (Environment.get_current_dir (), install_directory);

            var contents = "# This file is automatically generated by the Bake configure stage\n";
            var iter = HashTableIter<string, string> (conf_variables);
            while (true)
            {
                string name, value;
                if (!iter.next (out name, out value))
                    break;
                contents += "%s=%s\n".printf (name, value);
            }

            try
            {
                FileUtils.set_contents (Path.build_filename (toplevel_dir, "Recipe.conf"), contents);
            }
            catch (FileError e)
            {
                printerr ("Failed to write configuration: %s\n", e.message);
                return Posix.EXIT_FAILURE;
            }

            /* Stop if only configure stage requested */
            if (do_configure)
                return Posix.EXIT_SUCCESS;

            try
            {
                conf_file = new Recipe ("Recipe.conf");
            }
            catch (Error e)
            {
                printerr ("Failed to read back configuration: %s\n", e.message);
                return Posix.EXIT_FAILURE;
            }
        }

        /* Derived values */
        var resource_directory = conf_file.get_variable ("resource-directory");
        if (conf_file.get_variable ("binary-directory") == null)
            conf_file.set_variable ("binary-directory", "%s/bin".printf (resource_directory));
        if (conf_file.get_variable ("library-directory") == null)
            conf_file.set_variable ("library-directory", "%s/lib".printf (resource_directory));
        if (conf_file.get_variable ("data-directory") == null)
            conf_file.set_variable ("data-directory", "%s/share".printf (resource_directory));
        if (conf_file.get_variable ("include-directory") == null)
            conf_file.set_variable ("include-directory", "%s/include".printf (resource_directory));
        var data_directory = conf_file.get_variable ("data-directory");
        if (conf_file.get_variable ("package-data-directory") == null)
            conf_file.set_variable ("package-data-directory", "%s/$(package|name)".printf (data_directory));

        /* Load the recipe tree */
        var filename = Path.build_filename (toplevel_dir, "Recipe");
        try
        {
            toplevel = load_recipes (filename);
        }
        catch (Error e)
        {
            printerr ("Unable to build: %s\n", e.message);
            return Posix.EXIT_FAILURE;
        }

        /* Make the configuration the toplevel file so everything inherits from it */
        conf_file.children.append (toplevel);
        toplevel.parent = conf_file;

        /* Generate implicit rules */
        foreach (var module in modules)
            module.generate_toplevel_rules (toplevel);

        /* Generate libraries first (as other things may depend on it) then the other rules */
        /* FIXME: Stop this failing the build, instead print errors in the build rule */
        if (!generate_library_rules (toplevel) ||
            !generate_program_rules (toplevel) ||
            !generate_rules (toplevel))
        {
            GLib.print ("\x1B[1m\x1B[31m[Build failed in directory %s]\x1B[0m\n".printf (get_relative_path (original_dir, Environment.get_current_dir ())));
            return Posix.EXIT_FAILURE;
        }

        /* Generate clean rule */
        generate_clean_rules (toplevel);

        recipe_complete (toplevel);
        foreach (var module in modules)
            module.rules_complete (toplevel);

        /* Find the recipe in the current directory */
        var recipe = toplevel;
        while (recipe.dirname != original_dir)
        {
            foreach (var c in recipe.children)
            {
                var dir = original_dir + "/";
                if (dir.has_prefix (c.dirname + "/"))
                {
                    recipe = c;
                    break;
                }
            }
        }

        if (do_expand)
        {
            recipe.print ();
            return Posix.EXIT_SUCCESS;
        }

        string target = "build";
        if (args.length >= 2)
            target = args[1];

        GLib.print ("\x1B[1m[Building target %s]\x1B[0m\n", target);

        try
        {
            recipe.build_target (target);
        }
        catch (BuildError e)
        {
            printerr ("%s\n", e.message);
            /* FIXME: Say what rule we were trying to build */
            GLib.print ("\x1B[1m\x1B[31m[Build failed in directory %s]\x1B[0m\n".printf (get_relative_path (original_dir, Environment.get_current_dir ())));
            return Posix.EXIT_FAILURE;
        }

        GLib.print ("\x1B[1m\x1B[32m[Build complete]\x1B[0m\n");
        return Posix.EXIT_SUCCESS;
    }
}
