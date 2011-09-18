private bool do_expand = false;
private bool debug_enabled = false;

private string original_dir;

private void change_directory (string dirname)
{
    if (Environment.get_current_dir () == dirname)
        return;

    GLib.print ("\x1B[1m[Entering directory %s]\x1B[21m\n", get_relative_path (dirname));
    Environment.set_current_dir (dirname);
}

public string get_relative_path (string path)
{
    var current_dir = original_dir;
    
    if (path == current_dir)
        return ".";

    var dir = current_dir + "/";
    if (path.has_prefix (dir))
        return path.substring (dir.length);

    var relative_path = Path.get_basename (path);
    while (true)
    {
        current_dir = Path.get_dirname (current_dir);
        relative_path = "../" + relative_path;

        if (path.has_prefix (current_dir + "/"))
            return relative_path;
    }
}

private string remove_extension (string filename)
{
    var i = filename.last_index_of_char ('.');
    if (i < 0)
        return filename;
    return filename.substring (0, i);
}

private string replace_extension (string filename, string extension)
{
    var i = filename.last_index_of_char ('.');
    if (i < 0)
        return "%s.%s".printf (filename, extension);

    return "%.*s.%s".printf (i, filename, extension);
}

public class Rule
{
    public List<string> inputs;
    public List<string> outputs;
    public List<string> commands;

    public bool has_output
    {
        get { return outputs.length () > 0 && !outputs.nth_data (0).has_prefix ("%"); }
    }

    private TimeVal? get_modification_time (string filename) throws Error
    {
        var f = File.new_for_path (filename);
        var info = f.query_info (FILE_ATTRIBUTE_TIME_MODIFIED, FileQueryInfoFlags.NONE);

        GLib.TimeVal modification_time;
        info.get_modification_time (out modification_time);

        return modification_time;
    }
    
    private static int timeval_cmp (TimeVal a, TimeVal b)
    {
        if (a.tv_sec == b.tv_sec)
            return (int) (a.tv_usec - b.tv_usec);
        else
            return (int) (a.tv_sec - b.tv_sec);
    }

    public bool needs_build ()
    {
       TimeVal max_input_time = { 0, 0 };
       foreach (var input in inputs)
       {
           TimeVal modification_time;
           try
           {
               modification_time = get_modification_time (input);
           }
           catch (Error e)
           {
               if (!(e is IOError.NOT_FOUND))
                   warning ("Unable to access input file %s: %s", input, e.message);
               return true;
           }
           if (timeval_cmp (modification_time, max_input_time) > 0)
               max_input_time = modification_time;
       }

       var do_build = false;
       foreach (var output in outputs)
       {
           if (output.has_prefix ("%"))
               return true;

           TimeVal modification_time;
           try
           {
               modification_time = get_modification_time (output);
           }
           catch (Error e)
           {
               // FIXME: Only if opened
               do_build = true;
               continue;
           }
           if (timeval_cmp (modification_time, max_input_time) < 0)
              do_build = true;
       }

       return do_build;
    }

    public bool build ()
    {
        foreach (var c in commands)
        {
            if (c.has_prefix ("@"))
                c = c.substring (1);
            else
                print ("    %s\n", c);

            var exit_status = Posix.system (c);
            if (Process.if_signaled (exit_status))
            {
                printerr ("Build stopped with signal %d\n", Process.term_sig (exit_status));
                return false;
            }
            if (Process.if_exited (exit_status) && Process.exit_status (exit_status) != 0)
            {
                printerr ("Build stopped with return value %d\n", Process.exit_status (exit_status));               
                return false;
            }
        }

        foreach (var output in outputs)
        {
            if (!output.has_prefix ("%") && !FileUtils.test (output, FileTest.EXISTS))
            {
                GLib.printerr ("Failed to build file %s\n", output);
                return false;
            }
        }

       return true;
    }
}

public errordomain BuildError 
{
    NO_BUILDFILE,
    NO_TOPLEVEL,
    INVALID
}

public class BuildFile
{
    public string dirname;
    public BuildFile? parent;
    public List<BuildFile> children;
    public HashTable<string, string> variables;
    public List<string> programs;
    public List<string> files;
    public List<Rule> rules;

    public BuildFile (string filename) throws FileError, BuildError
    {
        dirname = Path.get_dirname (filename);

        variables = new HashTable<string, string> (str_hash, str_equal);

        string contents;
        FileUtils.get_contents (filename, out contents);
        var lines = contents.split ("\n");
        var line_number = 0;
        var in_rule = false;
        string? rule_indent = null;
        foreach (var line in lines)
        {
            line_number++;

            var i = 0;
            while (line[i].isspace ())
                i++;
            var indent = line.substring (0, i);
            var statement = line.substring (i);

            statement = statement.chomp ();

            if (in_rule)
            {
                if (rule_indent == null)
                    rule_indent = indent;

                if (indent == rule_indent)
                {
                    var rule = rules.last ().data;
                    rule.commands.append (statement);
                    continue;
                }
                in_rule = false;
            }

            if (statement == "")
                continue;
            if (statement.has_prefix ("#"))
                continue;

            /* Load variables */
            var index = statement.index_of ("=");
            if (index > 0)
            {
                var name = statement.substring (0, index).chomp ();
                variables.insert (name, statement.substring (index + 1).strip ());

                var tokens = name.split (".");
                if (tokens.length > 1 && tokens[0] == "programs")
                {
                    var program_name = tokens[1];
                    var has_name = false;
                    foreach (var p in programs)
                    {
                        if (p == program_name)
                        {
                            has_name = true;
                            break;
                        }
                    }
                    if (!has_name)
                        programs.append (program_name);
                }
                else if (tokens.length > 1 && tokens[0] == "files")
                {
                    var files_type = tokens[1];
                    var has_name = false;
                    foreach (var p in files)
                    {
                        if (p == files_type)
                        {
                            has_name = true;
                            break;
                        }
                    }
                    if (!has_name)
                        files.append (files_type);
                }

                continue;
            }

            /* Load explicit rules */
            index = statement.index_of (":");
            if (index > 0)
            {
                var rule = new Rule ();

                var input_list = statement.substring (0, index).chomp ();
                foreach (var output in input_list.split (" "))
                    rule.outputs.append (output);

                var output_list = statement.substring (index + 1).strip ();
                foreach (var input in output_list.split (" "))
                    rule.inputs.append (input);

                rules.append (rule);
                in_rule = true;
                continue;
            }

            throw new BuildError.INVALID ("Invalid statement in %s line %d:\n%s",
                                          get_relative_path (filename), line_number, statement);
        }
    }
    
    public void generate_rules ()
    {
        /* Add predefined variables */
        variables.insert ("files.project.install-dir", "/usr/local/share/%s".printf (toplevel.variables.lookup ("package.name")));
        variables.insert ("files.application.install-dir", "/usr/local/share/applications");
        variables.insert ("files.gsettings-schemas.install-dir", "/usr/local/share/glib-2.0/schemas");

        var build_rule = new Rule ();
        build_rule.outputs.append ("%build");
        foreach (var child in children)
            build_rule.inputs.append ("%s/build".printf (Path.get_basename (child.dirname)));
        rules.append (build_rule);

        var install_rule = new Rule ();
        install_rule.outputs.append ("%install");
        foreach (var child in children)
            install_rule.inputs.append ("%s/install".printf (Path.get_basename (child.dirname)));
        rules.append (install_rule);

        /* Intltool rules */
        var intltool_source_list = variables.lookup ("intltool.xml-sources");
        if (intltool_source_list != null)
        {
            var sources = intltool_source_list.split (" ");
            foreach (var source in sources)
            {
                var rule = new Rule ();
                rule.inputs.append (source);
                var output = remove_extension (source);
                rule.outputs.append (output);
                rule.commands.append ("LC_ALL=C intltool-merge --xml-style /dev/null %s %s".printf (source, output));
                rules.append (rule);

                build_rule.inputs.append (output);
            }
        }
        intltool_source_list = variables.lookup ("intltool.desktop-sources");
        if (intltool_source_list != null)
        {
            var sources = intltool_source_list.split (" ");
            foreach (var source in sources)
            {
                var rule = new Rule ();
                rule.inputs.append (source);
                var output = remove_extension (source);
                rule.outputs.append (output);
                rule.commands.append ("LC_ALL=C intltool-merge --desktop-style -u /dev/null %s %s".printf (source, output));
                rules.append (rule);

                build_rule.inputs.append (output);
            }
        }

        /* Man rules */
        var man_page_list = variables.lookup ("man.pages");
        if (man_page_list != null)
        {
            var pages = man_page_list.split (" ");
            foreach (var page in pages)
            {
                var i = page.last_index_of_char ('.');
                var number = 0;
                if (i > 0)
                    number = int.parse (page.substring (i + 1));
                if (number == 0)
                {
                    warning ("Not a valid man page name '%s'", page);
                    continue;
                }
                install_rule.inputs.append (page);
                install_rule.commands.append ("install %s /usr/share/man/man%d/%s".printf (page, number, page));
            }
        }

        /* GSettings rules */
        var gsettings_schema_list = variables.lookup ("gsettings.schemas");
        if (gsettings_schema_list != null)
        {
            var schemas = gsettings_schema_list.split (" ");
            foreach (var schema in schemas)
            {
                install_rule.inputs.append (schema);
                install_rule.commands.append ("install %s /usr/share/glib-2.0/schemas/%s".printf (schema, schema));
            }
        }

        /* Desktop rules */
        var desktop_entry_list = variables.lookup ("desktop.entries");
        if (desktop_entry_list != null)
        {
            var entries = desktop_entry_list.split (" ");
            foreach (var entry in entries)
            {
                install_rule.inputs.append (entry);
                install_rule.commands.append ("install %s /usr/share/applications/%s".printf (entry, entry));
            }
        }

        foreach (var program in programs)
        {
            var source_list = variables.lookup ("programs.%s.sources".printf (program));
            if (source_list == null)
                continue;

            var sources = source_list.split (" ");
            
            var package_list = variables.lookup ("programs.%s.packages".printf (program));
            var cflags = variables.lookup ("programs.%s.cflags".printf (program));
            var ldflags = variables.lookup ("programs.%s.ldflags".printf (program));

            string? package_cflags = null;
            string? package_ldflags = null;
            if (package_list != null)
            {
                int exit_status;
                try
                {
                    Process.spawn_command_line_sync ("pkg-config --cflags %s".printf (package_list), out package_cflags, null, out exit_status);
                    package_cflags = package_cflags.strip ();
                }
                catch (SpawnError e)
                {
                }
                try
                {
                    Process.spawn_command_line_sync ("pkg-config --libs %s".printf (package_list), out package_ldflags, null, out exit_status);
                    package_ldflags = package_ldflags.strip ();
                }
                catch (SpawnError e)
                {
                }
            }

            var linker = "gcc";
            List<string> objects = null;

            /* Vala compile */
            var rule = new Rule ();
            var command = "valac -C";
            if (package_list != null)
            {
                foreach (var package in package_list.split (" "))
                    command += " --pkg %s".printf (package);
            }
            foreach (var source in sources)
            {
                if (!source.has_suffix (".vala") && !source.has_suffix (".vapi"))
                    continue;

                rule.inputs.append (source);
                if (source.has_suffix (".vala"))
                    rule.outputs.append (replace_extension (source, "c"));
                command += " %s".printf (source);
            }
            if (rule.outputs != null)
            {
                rule.commands.append (command);
                rules.append (rule);
            }

            /* Java compile */
            rule = new Rule ();
            var jar_rule = new Rule ();
            var jar_file = "%s.jar".printf (program);
            jar_rule.outputs.append (jar_file);
            var jar_command = "jar cf %s".printf (jar_file);
            command = "javac";
            foreach (var source in sources)
            {
                if (!source.has_suffix (".java"))
                    continue;

                var class_file = replace_extension (source, "class");

                jar_rule.inputs.append (class_file);
                jar_command += " %s".printf (class_file);

                rule.inputs.append (source);
                rule.outputs.append (class_file);
                command += " %s".printf (source);
            }
            if (rule.outputs != null)
            {
                rule.commands.append (command);
                rules.append (rule);
                build_rule.inputs.append (jar_file);
                jar_rule.commands.append (jar_command);
                rules.append (jar_rule);
            }

            /* C++ compile */
            foreach (var source in sources)
            {
                if (!source.has_suffix (".cpp") && !source.has_suffix (".C"))
                    continue;

                var output = replace_extension (source, "o");

                linker = "g++";
                objects.append (output);

                rule = new Rule ();
                rule.inputs.append (source);
                rule.outputs.append (output);
                command = "@g++ -g -Wall";
                if (cflags != null)
                    command += " %s".printf (cflags);
                if (package_cflags != null)
                    command += " %s".printf (package_cflags);
                command += " -c %s -o %s".printf (source, output);
                rule.commands.append ("@echo '    CC %s'".printf (source));
                rule.commands.append (command);
                rules.append (rule);
            }

            /* C compile */
            foreach (var source in sources)
            {
                if (!source.has_suffix (".vala") && !source.has_suffix (".c"))
                    continue;

                var input = replace_extension (source, "c");
                var output = replace_extension (source, "o");

                objects.append (output);

                rule = new Rule ();
                rule.inputs.append (input);
                rule.outputs.append (output);
                command = "@gcc -g -Wall";
                if (cflags != null)
                    command += " %s".printf (cflags);
                if (package_cflags != null)
                    command += " %s".printf (package_cflags);
                command += " -c %s -o %s".printf (input, output);
                rule.commands.append ("@echo '    CC %s'".printf (input));
                rule.commands.append (command);
                rules.append (rule);
            }

            /* Link */
            if (objects.length () > 0)
            {
                build_rule.inputs.append (program);

                rule = new Rule ();
                foreach (var o in objects)
                    rule.inputs.append (o);
                rule.outputs.append (program);
                command = "@%s -g -Wall".printf (linker);
                foreach (var o in objects)
                    command += " %s".printf (o);
                rule.commands.append ("@echo '    LD %s'".printf (program));
                if (ldflags != null)
                    command += " %s".printf (ldflags);
                if (package_ldflags != null)
                    command += " %s".printf (package_ldflags);
                command += " -o %s".printf (program);
                rule.commands.append (command);
                rules.append (rule);
            }
        }

        foreach (var program in programs)
        {
            var source = program;
            var target = Path.build_filename ("/usr/local/bin", program);
            install_rule.inputs.append (source);
            install_rule.commands.append ("install %s %s".printf (source, target));
        }
        foreach (var file_class in files)
        {
            var file_list = variables.lookup ("files.%s".printf (file_class));

            /* Only install files that are requested to */
            var install_dir = variables.lookup ("files.%s.install-dir".printf (file_class));
            if (install_dir == null)
                continue;

            if (file_list != null)
            {
                foreach (var file in file_list.split (" "))
                {
                    var source = file;
                    var target = Path.build_filename (install_dir, file);
                    install_rule.inputs.append (source);
                    install_rule.commands.append ("install %s %s".printf (source, target));
                }
            }
        }

        foreach (var child in children)
            child.generate_rules ();
    }

    public void generate_clean_rule ()
    {
        var clean_rule = new Rule ();
        clean_rule.outputs.append ("%clean");
        foreach (var child in children)
            clean_rule.inputs.append ("%s/clean".printf (Path.get_basename (child.dirname)));
        rules.append (clean_rule);
        foreach (var rule in rules)
        {
            foreach (var output in rule.outputs)
            {
                if (output.has_prefix ("%"))
                    continue;
                clean_rule.commands.append ("@echo '    RM %s'".printf (output));
                if (output.has_suffix ("/"))
                {
                    /* Don't accidentally delete someone's entire hard-disk */
                    if (output.has_prefix ("/"))
                        warning ("Not making clean rule for absolute directory %s", output);
                    else
                        clean_rule.commands.append ("@rm -rf %s".printf (output));
                }
                else
                    clean_rule.commands.append ("@rm -f %s".printf (output));
            }
        }

        foreach (var child in children)
            child.generate_clean_rule ();
    }
    
    public bool is_toplevel
    {
        get { return variables.lookup ("package.name") != null; }
    }

    public BuildFile toplevel
    {
        get { if (is_toplevel) return this; else return parent.toplevel; }
    }

    public string get_relative_dirname ()
    {
        if (is_toplevel)
            return ".";
        else
            return dirname.substring (toplevel.dirname.length + 1);
    }

    public Rule? find_rule (string output)
    {
        foreach (var rule in rules)
        {
            foreach (var o in rule.outputs)
            {
                if (o.has_prefix ("%"))
                    o = o.substring (1);
                if (o == output)
                    return rule;
            }
        }

        return null;
    }
    
    public BuildFile get_buildfile_with_target (string target)
    {
        /* Build in the directory that contains this */
        var dir = Path.get_dirname (target);
        if (dir != ".")
        {
            var child_dir = Path.build_filename (dirname, dir);
            foreach (var child in children)
            {
                if (child.dirname == child_dir)
                    return child;
            }
        }

        return this;
    }
    
    public bool build_target (string target)
    {
        var buildfile = get_buildfile_with_target (target);
        if (buildfile != this)
            return buildfile.build_target (Path.get_basename (target));

        var rule = find_rule (target);
        if (rule == null)
        {
            var path = Path.build_filename (dirname, target);

            if (FileUtils.test (path, FileTest.EXISTS))
                return true;
            else
            {
                GLib.printerr ("No rule to build '%s'\n", get_relative_path (target));
                return false;
            }
        }

        if (!rule.needs_build ())
            return true;

        /* Build all the inputs */
        foreach (var input in rule.inputs)
        {
            if (!build_target (input))
                return false;
        }

        /* Run the commands */
        change_directory (dirname);
        if (rule.has_output)
            GLib.print ("\x1B[1m[Building %s]\x1B[21m\n", target);
        return rule.build ();
    }
    
    public bool build ()
    {
        foreach (var program in programs)
        {
            if (!build_target (program))
                return false;
        }

        return true;
    }

    public void print ()
    {
        foreach (var name in variables.get_keys ())
            GLib.print ("%s=%s\n", name, variables.lookup (name));
        foreach (var rule in rules)
        {
            GLib.print ("\n");
            foreach (var output in rule.outputs)
                GLib.print ("%s ", output);
            GLib.print (":");
            foreach (var input in rule.inputs)
                GLib.print (" %s", input);
            GLib.print ("\n");
            foreach (var c in rule.commands)
                GLib.print ("    %s\n", c);
        }
    }
}

public class EasyBuild
{
    private static bool show_version = false;
    public static const OptionEntry[] options =
    {
        { "expand", 0, 0, OptionArg.NONE, ref do_expand,
          /* Help string for command line --expand flag */
          N_("Expand current Buildfile and print to stdout"), null},
        { "version", 'v', 0, OptionArg.NONE, ref show_version,
          /* Help string for command line --version flag */
          N_("Show release version"), null},
        { "debug", 'd', 0, OptionArg.NONE, ref debug_enabled,
          /* Help string for command line --debug flag */
          N_("Print debugging messages"), null},
        { null }
    };

    public static BuildFile? load_buildfiles (string filename, BuildFile? child = null) throws Error
    {    
        if (debug_enabled)
            debug ("Loading %s", filename);

        BuildFile f;
        try
        {
            f = new BuildFile (filename);
        }
        catch (FileError e)
        {
            if (e is FileError.NOENT)
            {
                if (child == null)
                    throw new BuildError.NO_BUILDFILE ("No Buildfile in current directory");
                else
                    throw new BuildError.NO_TOPLEVEL ("%s is missing package.name variable",
                                                      get_relative_path (child.dirname + "/Buildfile"));
            }
            else
                throw e;
        }

        /* Find the toplevel buildfile */
        if (!f.is_toplevel)
        {
            var parent_dir = Path.get_dirname (f.dirname);
            f.parent = load_buildfiles (Path.build_filename (parent_dir, "Buildfile"), f);
        }

        /* Load children */
        var dir = Dir.open (f.dirname);
        while (true)
        {
            var child_dir = dir.read_name ();
            if (child_dir == null)
                 break;

            /* Already loaded */
            if (child != null && Path.build_filename (f.dirname, child_dir) == child.dirname)
            {
                child.parent = f;
                f.children.append (child);
                continue;
            }

            var child_filename = Path.build_filename (f.dirname, child_dir, "Buildfile");
            if (FileUtils.test (child_filename, FileTest.EXISTS))
            {
                if (debug_enabled)
                    debug ("Loading %s", child_filename);
                var c = new BuildFile (child_filename);
                c.parent = f;
                f.children.append (c);
            }
        }

        return f;
    }

    private static void add_release_file (Rule release_rule, string temp_dir, string directory, string filename)
    {
        var input_filename = Path.build_filename (directory, filename);
        var output_filename = Path.build_filename (temp_dir, directory, filename);
        if (directory == ".")
        {
            input_filename = filename;
            output_filename = Path.build_filename (temp_dir, filename);
        }

        var has_dir = false;
        foreach (var input in release_rule.inputs)
        {
            /* Ignore if already being copied */
            if (input == input_filename)
                return;

            if (!has_dir && Path.get_dirname (input) == Path.get_dirname (input_filename))
                has_dir = true;
        }

        /* Generate directory if a new one */
        if (!has_dir)
            release_rule.commands.append ("mkdir -p %s".printf (Path.get_dirname (output_filename)));

        release_rule.inputs.append (input_filename);
        release_rule.commands.append ("cp %s %s".printf (input_filename, output_filename));
    }
    
    public static void generate_release_rule (BuildFile buildfile, Rule release_rule, string temp_dir)
    {
        var relative_dirname = buildfile.get_relative_dirname ();

        var dirname = Path.build_filename (temp_dir, relative_dirname);
        if (relative_dirname == ".")
            dirname = temp_dir;

        /* Add files that are used */
        add_release_file (release_rule, temp_dir, relative_dirname, "Buildfile");
        foreach (var rule in buildfile.rules)
        {
            foreach (var input in rule.inputs)
            {
                /* Ignore generated files */
                if (buildfile.find_rule (input) != null)
                    continue;

                /* Ignore files built in other buildfiles */
                if (buildfile.get_buildfile_with_target (input) != buildfile)
                    continue;

                add_release_file (release_rule, temp_dir, relative_dirname, input);
            }
        }

        foreach (var child in buildfile.children)
            generate_release_rule (child, release_rule, temp_dir);
    }

    public static int main (string[] args)
    {
        original_dir = Environment.get_current_dir ();

        var c = new OptionContext (/* Arguments and description for --help text */
                                   _("[TARGET] - Build system"));
        c.add_main_entries (options, Config.GETTEXT_PACKAGE);
        try
        {
            c.parse (ref args);
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
            stderr.printf ("easy-build %s\n", Config.VERSION);
            return Posix.EXIT_SUCCESS;
        }

        var filename = Path.build_filename (Environment.get_current_dir (), "Buildfile");
        BuildFile f;
        try
        {
            f = load_buildfiles (filename);
        }
        catch (Error e)
        {
            printerr ("Unable to build: %s\n", e.message);
            return Posix.EXIT_FAILURE;
        }
        var toplevel = f.toplevel;

        /* Generate implicit rules */
        toplevel.generate_rules ();

        /* Generate release rules */
        var package_name = toplevel.variables.lookup ("package.name");
        var release_name = package_name;
        var version = toplevel.variables.lookup ("package.version");
        if (version != null)
            release_name += "-" + version;
        var release_dir = "%s/".printf (release_name);

        var rule = new Rule ();
        rule.outputs.append (release_dir);
        generate_release_rule (toplevel, rule, release_name);
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.inputs.append (release_dir);
        rule.outputs.append ("%s.tar.gz".printf (release_name));
        rule.commands.append ("tar --create --gzip --file %s.tar.gz %s".printf (release_name, release_name));
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.outputs.append ("%release-gzip");
        rule.inputs.append ("%s.tar.gz".printf (release_name));
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.inputs.append (release_dir);
        rule.outputs.append ("%s.tar.bz2".printf (release_name));
        rule.commands.append ("tar --create --bzip2 --file %s.tar.bz2 %s".printf (release_name, release_name));
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.outputs.append ("%release-bzip");
        rule.inputs.append ("%s.tar.bz2".printf (release_name));
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.inputs.append (release_dir);
        rule.outputs.append ("%s.tar.xz".printf (release_name));
        rule.commands.append ("tar --create --xz --file %s.tar.xz %s".printf (release_name, release_name));
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.outputs.append ("%release-xzip");
        rule.inputs.append ("%s.tar.xz".printf (release_name));
        toplevel.rules.append (rule);

        rule = new Rule ();
        rule.outputs.append ("%release-gnome");
        rule.inputs.append ("%s.tar.xz".printf (release_name));
        rule.commands.append ("scp %s.tar.xz master.gnome.org:".printf (release_name));
        rule.commands.append ("ssh master.gnome.org install-module %s.tar.xz". printf (release_name));
        toplevel.rules.append (rule);

        if (version != null)
        {
            var package_version = "0";

            var orig_file = "%s_%s.orig.tar.gz".printf (package_name, version);
            var debian_file = "%s_%s-%s.debian.tar.gz".printf (package_name, version, package_version);
            var changes_file = "%s_%s-%s_source.changes".printf (package_name, version, package_version);
            var dsc_file = "%s_%s-%s.dsc".printf (package_name, version, package_version);

            rule = new Rule ();
            rule.outputs.append (orig_file);
            rule.outputs.append (debian_file);
            rule.outputs.append (dsc_file);
            rule.outputs.append (changes_file);
            rule.inputs.append (release_dir);
            rule.commands.append ("@tar --create --gzip --file %s %s".printf (orig_file, release_name));
            rule.commands.append ("@mkdir -p %s/debian".printf (release_name));

            /* Generate debian/changelog */
            var changelog_file = "%s/debian/changelog".printf (release_name);
            var distribution = "oneiric";
            var name = Environment.get_real_name ();
            var email = Environment.get_variable ("DEBEMAIL");
            if (email == null)
                email = Environment.get_variable ("EMAIL");
            if (email == null)
                email = "%s@%s".printf (Environment.get_user_name (), Environment.get_host_name ());
            var now = Time.local (time_t ());
            var release_date = now.format ("%a, %d %b %Y %H:%M:%S %z");
            rule.commands.append ("@echo \"%s (%s-%s) %s; urgency=low\" > %s".printf (package_name, version, package_version, distribution, changelog_file));
            rule.commands.append ("@echo >> %s".printf (changelog_file));
            rule.commands.append ("@echo \"  * Initial release.\" >> %s".printf (changelog_file));
            rule.commands.append ("@echo >> %s".printf (changelog_file));
            rule.commands.append ("@echo \" -- %s <%s>  %s\" >> %s".printf (name, email, release_date, changelog_file));

            /* Generate debian/rules */
            var rules_file = "%s/debian/rules".printf (release_name);
            rule.commands.append ("@echo \"#!/usr/bin/make -f\" > %s".printf (rules_file));
            rule.commands.append ("@echo >> %s".printf (rules_file));
            rule.commands.append ("@echo \"build:\" >> %s".printf (rules_file));
            rule.commands.append ("@echo \"\teb\" >> %s".printf (rules_file));
            rule.commands.append ("@echo >> %s".printf (rules_file));
            rule.commands.append ("@echo \"binary: binary-arch binary-indep\" >> %s".printf (rules_file));
            rule.commands.append ("@echo >> %s".printf (rules_file));
            rule.commands.append ("@echo \"binary-arch: build\" >> %s".printf (rules_file));
            rule.commands.append ("@echo \"\teb install\" >> %s".printf (rules_file));
            rule.commands.append ("@echo >> %s".printf (rules_file));
            rule.commands.append ("@echo \"binary-indep: build\" >> %s".printf (rules_file));
            rule.commands.append ("@echo >> %s".printf (rules_file));
            rule.commands.append ("@echo \"clean:\" >> %s".printf (rules_file));
            rule.commands.append ("@echo \"\teb clean\" >> %s".printf (rules_file));
            rule.commands.append ("@echo chmod +x %s".printf (rules_file));

            /* Generate debian/control */
            var control_file = "%s/debian/control".printf (release_name);
            var build_depends = "easy-build";
            var short_description = "Short description of %s".printf (package_name);
            var long_description = "Long description of %s".printf (package_name);
            rule.commands.append ("@echo \"Source: %s\" > %s".printf (package_name, control_file));
            rule.commands.append ("@echo \"Maintainer: %s <%s>\" >> %s".printf (name, email, control_file));
            rule.commands.append ("@echo \"Build-Depends: %s\" >> %s".printf (build_depends, control_file));
            rule.commands.append ("@echo \"Standards-Version: 3.9.2\" >> %s".printf (control_file));
            rule.commands.append ("@echo >> %s".printf (control_file));
            rule.commands.append ("@echo \"Package: %s\" >> %s".printf (package_name, control_file));
            rule.commands.append ("@echo \"Architecture: any\" >> %s".printf (control_file));
            rule.commands.append ("@echo \"Description: %s\" >> %s".printf (short_description, control_file));
            foreach (var line in long_description.split ("\n"))
                rule.commands.append ("@echo \" %s\" >> %s".printf (line, control_file));

            /* Generate debian/source/format */
            rule.commands.append ("@mkdir -p %s/debian/source".printf (release_name));
            rule.commands.append ("@echo \"3.0 (quilt)\" > %s/debian/source/format".printf (release_name));

            rule.commands.append ("cd %s && dpkg-buildpackage -S".printf (release_name));
            toplevel.rules.append (rule);

            var ppa_name = toplevel.variables.lookup ("package.ppa");
            if (ppa_name != null)
            {
                rule = new Rule ();
                rule.outputs.append ("%release-ppa");
                rule.inputs.append (changes_file);
                rule.commands.append ("dput ppa:%s %s".printf (ppa_name, changes_file));
                toplevel.rules.append (rule);
            }
        }

        /* Generate clean rule */
        toplevel.generate_clean_rule ();

        if (do_expand)
        {
            f.print ();
            return Posix.EXIT_SUCCESS;
        }

        string target = "build";
        if (args.length >= 2)
            target = args[1];

        if (f.build_target (target))
            return Posix.EXIT_SUCCESS;
        else
            return Posix.EXIT_FAILURE;
    }
}
