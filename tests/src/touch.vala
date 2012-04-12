[CCode (cheader_filename = "sys/stat.h")]
extern int futimens (int fd, [CCode (array_length = false)] Posix.timespec[] times);

public class Touch
{
    public static int main (string[] args)
    {
        var status_socket_name = Environment.get_variable ("BAKE_TEST_STATUS_SOCKET");
        if (status_socket_name == null)
        {
            stderr.printf ("BAKE_TEST_STATUS_SOCKET not defined\n");
            return Posix.EXIT_FAILURE;
        }
        Socket socket;
        try
        {
            socket = new Socket (SocketFamily.UNIX, SocketType.DATAGRAM, SocketProtocol.DEFAULT);
            socket.connect (new UnixSocketAddress (status_socket_name));
        }
        catch (Error e)
        {
            stderr.printf ("Failed to open status socket: %s\n", e.message);
            return Posix.EXIT_FAILURE;
        }
        var message = "%s\n".printf (string.joinv (" ", args));
        try
        {
            socket.send (message.data);
        }
        catch (Error e)
        {
            stderr.printf ("Failed to write to status socket: %s\n", e.message);
        }

        for (var i = 1; args[i] != null; i++)
        {
            if (args[i].has_prefix ("-"))
                continue;

            var fd = Posix.open (args[i], Posix.O_WRONLY | Posix.O_CREAT, 0666);
            Posix.timespec times[2];
            Posix.clock_gettime (Posix.CLOCK_REALTIME, out times[0]);
            times[1] = times[0];
            futimens (fd, times);
            Posix.close (fd);
        }

        return Posix.EXIT_SUCCESS;
    }
}