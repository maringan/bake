public class RPMModule : BuildModule
{
    public override void generate_toplevel_rules (Recipe recipe)
    {
        if (recipe.package_version == null || Environment.find_program_in_path ("rpmbuild") == null)
            return;

        var release = "1";
        var summary = "Summary of %s".printf (recipe.package_name);
        var description = "Description of %s".printf (recipe.package_name);
        var license = "unknown";

        string rpmbuild_rc = "";
        int exit_status;
        try
        {
            Process.spawn_command_line_sync ("rpmbuild --showrc", out rpmbuild_rc, null, out exit_status);
        }
        catch (SpawnError e)
        {
            // FIXME
            warning ("Failed to get rpmbuild configuration");
        }

        var build_arch = "";
        try
        {
            var build_arch_regex = new Regex ("build arch\\s*:(.*)");
            MatchInfo info;
            if (build_arch_regex.match (rpmbuild_rc, 0, out info))
                build_arch = info.fetch (1).strip ();
        }
        catch (RegexError e)
        {
            warning ("Failed to make rpmbuild regex");
        }

        var build_dir = ".bake-rpm-builddir";
        var gzip_file = "%s.tar.gz".printf (recipe.release_name);
        var source_file = "%s.rpm.tar.gz".printf (recipe.package_name);
        var spec_file = "%s/%s/%s.spec".printf (build_dir, recipe.release_name, recipe.package_name);
        var rpm_file = "%s-%s-%s.%s.rpm".printf (recipe.package_name, recipe.package_version, release, build_arch);

        var rule = recipe.add_rule ();
        rule.add_input (gzip_file);
        rule.add_output (rpm_file);
        rule.add_command ("@rm -rf %s".printf (build_dir));
        rule.add_command ("@mkdir %s".printf (build_dir));
        rule.add_command ("@cd %s && tar --extract --gzip --file ../%s".printf (build_dir, gzip_file));
        rule.add_status_command ("Writing %s.spec".printf (recipe.package_name));
        rule.add_command ("@echo \"Summary: %s\" > %s".printf (summary, spec_file));
        rule.add_command ("@echo \"Name: %s\" >> %s".printf (recipe.package_name, spec_file));
        rule.add_command ("@echo \"Version: %s\" >> %s".printf (recipe.package_version, spec_file));
        rule.add_command ("@echo \"Release: %s\" >> %s".printf (release, spec_file));
        rule.add_command ("@echo \"License: %s\" >> %s".printf (license, spec_file));
        rule.add_command ("@echo \"Source: %s\" >> %s".printf (source_file, spec_file));
        rule.add_command ("@echo >> %s".printf (spec_file));
        rule.add_command ("@echo \"%%description\" >> %s".printf (spec_file));
        foreach (var line in description.split ("\n"))
            rule.add_command ("@echo \"%s\" >> %s".printf (line, spec_file));
        rule.add_command ("@echo >> %s".printf (spec_file));
        rule.add_command ("@echo \"%%prep\" >> %s".printf (spec_file));
        rule.add_command ("@echo \"%%setup -q\" >> %s".printf (spec_file));
        rule.add_command ("@echo >> %s".printf (spec_file));
        rule.add_command ("@echo \"%%build\" >> %s".printf (spec_file));
        rule.add_command ("@echo \"bake --configure resource-directory=/usr install-directory=\\$RPM_BUILD_ROOT\" >> %s".printf (spec_file));
        rule.add_command ("@echo \"bake\" >> %s".printf (spec_file));
        rule.add_command ("@echo >> %s".printf (spec_file));
        rule.add_command ("@echo \"%%install\" >> %s".printf (spec_file));
        rule.add_command ("@echo \"bake install\" >> %s".printf (spec_file));
        rule.add_command ("@echo \"find \\$RPM_BUILD_ROOT -type f -print | sed \\\"s#^\\$RPM_BUILD_ROOT/*#/#\\\" > FILE-LIST\" >> %s".printf (spec_file));
        rule.add_command ("@echo \"sed -i 's/\\/man\\/man.*/&*/' FILE-LIST\" >> %s".printf (spec_file));
        rule.add_command ("@echo >> %s".printf (spec_file));
        rule.add_command ("@echo \"%%files -f FILE-LIST\" >> %s".printf (spec_file));
        rule.add_command ("@echo >> %s".printf (spec_file));
        rule.add_command ("@cd %s && tar --create --gzip --file ../%s %s".printf (build_dir, source_file, recipe.release_name));
        rule.add_status_command ("RPM %s".printf (rpm_file));
        rule.add_command ("@rpmbuild -tb %s".printf (source_file));
        rule.add_command ("@cp %s/rpmbuild/RPMS/%s/%s .".printf (Environment.get_home_dir (), build_arch, rpm_file));
        rule.add_command ("@rm -f %s".printf (source_file));
        rule.add_command ("@rm -rf %s".printf (build_dir));

        rule = recipe.add_rule ();
        rule.add_input (rpm_file);
        rule.add_output ("%release-rpm");
   }
}
