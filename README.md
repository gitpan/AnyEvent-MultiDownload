# NAME

AnyEvent::MultiDownload - 非阻塞的多线程多地址文件下载的模块

# SYNOPSIS

这是一个非阻塞的多线程多地址文件下载的模块, 可以象下面这个应用一样, 同时下载多个文件, 并且整个过程都是异步事件触发, 不会阻塞主进程.

下面是个简单的例子, 同时从多个地址下载同一个文件.

    use AE;
    use AnyEvent::MultiDownload;

    my @urls = (
        'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso',
        'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso',
    );
    

    my $cv = AE::cv;
    my $MultiDown = AnyEvent::MultiDownload->new( 
        url     => pop @urls, 
        mirror  => \@urls, 
        content_file  => '/tmp/ubuntu.iso',
        seg_size => 1 * 1024 * 1024, # 1M
        on_seg_finish => sub {
            my ($hdr, $seg, $size, $chunk, $cb) = @_;
            $cb->(1);
        },
        on_finish => sub {
            my $len = shift;
            $cv->send;
        },
        on_error => sub {
            my $error = shift;
            $cv->send;
        }
    )->multi_get_file;
    

    $cv->recv;



下面是异步同时下载多个文件的实例. 整个过程异步.

    use AE;
    use AnyEvent::MultiDownload;
    

    my $cv = AE::cv;
    

    $cv->begin;
    my $MultiDown = AnyEvent::MultiDownload->new( 
        url     => 'http://xxx1',
        content_file  => "/tmp/file2",
        on_finish => sub {
            my $len = shift;
            $cv->end;
        },
        on_error => sub {
            my $error = shift;
            $cv->end;
        }
    );
    $MultiDown->multi_get_file;
    

    $cv->begin;
    my $MultiDown1 = AnyEvent::MultiDownload->new( 
        content_file  => "/tmp/file1",
        url     => 'http://xxx', 
        on_finish => sub {
            my $len = shift;
            $cv->end;
        },
        on_error => sub {
            my $error = shift;
            $cv->end;
        }
    );
    $MultiDown1->multi_get_file;
    

    $cv->recv;

以上是同时下载多个文件的实例.

# METHODS

创建一个多下载的对象.

    my $MultiDown = AnyEvent::MultiDownload->new( 
            url     => 'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso', 
            mirror  => ['http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso', 'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso'],
            content_file  => $content_file,
            seg_size => 1 * 1024 * 1024, # 1M
            on_seg_finish => sub {
                my ($hdr, $seg_path, $size, $chunk,  $cb) = @_;
                $cb->(1);
            },
            on_finish => sub {
                my $len = shift;
                $cv->send;
            },
            on_error => sub {
                my $error = shift;
                $cv->send;
            },
    

    );

- url => 下载的主地址

    这个是下载用的 master 的地址, 是主地址, 这个参数必须有.

- content\_file => 下载后的存放地址

    这个地址用于指定, 下载完了, 存放在什么位置. 这个参数必须有.

- mirror => 镜象地址

    这个是可以用来做备用地址和分块下载时用的地址. 需要一个数组引用, 其中放入这个文件的其它用于下载的地址. 如果块下载失败会自动切换成其它的地址下载. 本参数不是必须的.

- seg\_size => 下载块的大小

    默认这个 seg\_size 是指每次取块的大小,默认是 1M 一个块, 这个参数会给文件按照 1M 的大小来切成一个个块来下载并合并. 本参数不是必须的.



- retry\_interval => 重试的间隔 

    重试的间隔, 默认为 3 s.

- max\_retries => 最多重试的次数

    重试每个块所能重试的次数, 默认为 5 次.

- on\_seg\_finish => 每块的下载完回调

    当每下载完 1M 时,会回调一次, 你可以用于检查你的下载每块的完整性, 这个时候只有 200 和 206 响应的时候才会回调.

    回调传四个参数, 本块下载时响应的 header, 下载的块的实体二进制内容, 下载块的大小, 当前是第几块 检查完后的回调. 这时如果回调为 1 证明检查结果正常, 如果为 0 证明检查失败, 会在次重新下载本块. 

    默认模块会帮助检查大小, 所以大小不用对比和检查了, 可以给每块的 MD5 记录下来, 使用这个来对比. 本参数不是必须的. 如果没有这个回调默认检查大小正确.

- on\_finish

    当整个文件下载完成时的回调, 下载完成的回调会传一个下载的文件大小的参数过来. 这个回调必须存在.

- on\_error

    当整个文件下载过程出错时回调, 这个参数必须存在, 因为不能保证每次下载都能正常.

- timeout

    下载多久算超时, 可选参数, 默认为 60s.

- recurse 重定向

    如果请求过程中有重定向, 可以最多重定向多少次.

## multi\_get\_file()

事件开始的方法. 只有调用这个函数时, 这个下载的事件才开始执行.

# AUTHOR

扶凯 fukai <iakuf@163.com>
