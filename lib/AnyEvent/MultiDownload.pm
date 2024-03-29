#!/usr/bin/perl
package AnyEvent::MultiDownload;
use strict;
use AnyEvent::HTTP qw/http_get/;
use AnyEvent::Util;
use AnyEvent::Socket;
use AnyEvent::IO;
use AE;
use Moo;
use File::Temp;
use File::Copy;
use File::Basename;
use List::Util qw/shuffle/;
use AnyEvent::Digest;
use utf8;

our $VERSION = '1.08';


has content_file => (
    is => 'ro',
    isa => sub {
        die "文件存在" if -e $_[0];
    },
    required => 1,
);

has url => (
    is  => 'ro',
    required => 1,
);

has mirror => (
    is => 'rw',
    predicate => 1,
    isa => sub {
        return 1 if ref $_[0] eq 'ARRAY';
    },
);

has digest => (
    is => 'rw',
    isa => sub {
        return 1 if $_[0] =~ /Digest::(SHA|MD5)/;
    }
);


has on_finish => (
    is => 'rw',
    required => 1,
    isa => sub {
        return 2 if ref $_[0] eq 'CODE';
    }
);

has on_error => (
    is => 'rw',
    isa => sub {
        return 2 if ref $_[0] eq 'CODE';
    },
    default => sub {  sub { 1 } },
);

has on_seg_finish => (
    is => 'rw',
    isa => sub {
        return 2 if ref $_[0] eq 'CODE';
    },
    default => sub {  
        return sub { $_[-1]->(1) } 
    },
);

has fh       => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $out = File::Temp->new(UNLINK => 1); 
        $out->autoflush(1);
        return $out;
    },
);

has retry_interval => is => 'rw', default => sub { 10 };
has max_retries    => is => 'rw', default => sub { 5 };
has seg_size       => is => 'rw', default => sub { 1 * 1024 * 1024 };
has timeout        => is => 'rw', default => sub { 60 };
has recurse        => is => 'rw', default => sub { 6 }; 
has headers        => is => 'rw', default => sub {{}};
has tasks          => is => 'rw', default => sub { [] };
has error          => is => 'rw', default => sub {};
has task_lists     => is => 'rw', default => sub {[]};
has max_per_host   => is => 'rw', default => sub { 8 };
has url_status  => (
    is      => 'rw', 
    lazy    => 1,
    default => sub { 
        my $self = shift;
        my %hash;
        if ($self->has_mirror) {
            %hash = map {
                        $_ => 0
                    } @{ $self->mirror }, $self->url;
        }
        else {
            $hash{$self->url} = 0;
        }
        return \%hash;
    }
);


sub multi_get_file  {
    my $self = shift;
    my $cb   = shift;
    
    # 用于做事件同步
    my $cv = AE::cv { 
        my $cv = shift;

	    if ($cv->recv) {
            # 有一个不能处理的出错的时候, 发出去的连接都要断开掉, 所以使用这个
            $self->task_lists(undef);
	        $self->clean;
	    	$self->on_error->($self->error);
	    }
	    else {
        	$self->move_to;
        	$self->on_finish->($self->size);
	    }

        undef $cv;
    };

    my $first_task;
    my $run; $run = sub {
        my $retry = shift || 0;
        my $url = $self->shuffle_url;
        my $ev; $ev = http_get $url,
            headers     => $self->headers, 
            timeout     => $self->timeout,
            recurse     => $self->recurse,
            on_header   => sub {
                my ($hdr) = @_;
                if ( $hdr->{Status} == 200 ) {
                    my $len = $hdr->{'content-length'};

                    if (!defined($len)) {
                        $self->error("Cannot find a content-length header.");
                    }

                    # 准备开始下载的信息
                    my $ranges = $self->split_range($len);

                    # 除了第一个块, 其它块现在开始下载
                    # 事件开始, 但这个回调会在最后才调用.
                    $first_task = shift @{ $self->tasks };
                    $first_task->{chunk} = $first_task->{chunk} || 0;
                    $first_task->{ofs}   = $first_task->{ofs}   || 0;
                    return 1 if $len <= $self->seg_size;

                    for ( 1 .. $self->max_per_host ) {
                        my $chunk_task = shift @{ $self->tasks };
                        last unless defined $chunk_task;
                        $cv->begin;
                        $self->fetch_chunk( $cv, $chunk_task) ;
                    }
                }
                1
            },
            on_body   => sub {
                my ($partial_body, $hdr) = @_;
                if ( $self->on_body($first_task)->($partial_body, $hdr) ) {
                    # 如果是第一个块的话, 下载到指定的大小就需要断开
                    if ( ( $hdr->{'content-length'} <= $self->seg_size and  $first_task->{size} == $hdr->{'content-length'} )
                            or 
                            $first_task->{size} >= $self->seg_size
                        ) {
                        $self->on_seg_finish->( 
                             $hdr,
                             $first_task, 
                             $self->digest ? $first_task->{ctx}->hexdigest : '', 
                        sub {

                            my ($result, $error) = @_;
                            # 2. 大小相等, 块较检不相等 | 直接失败
                            if ($result) {
		                        $cv->end;  # 完成第一个块
                            }
                            else {
                                $self->error("The 0 block the compared failure");
                                $self->url_status->{$url}++;
                                $cv->send(1); # 失败, 结束整个请求
                                AE::log debug => $self->error;
                                return;
                            }
                        });
                        return 0
                    }
                }
                return 1;
            },
            sub {
                my (undef, $hdr) = @_;
                undef $ev;
                my $status = $hdr->{Status};
                if ( $retry > $self->max_retries ) {
		            $self->error( 
                        sprintf("Status: %s, Reason: %s.", 
			        	    $status ? $status : '500', 
                            $hdr->{Reason} ? $hdr->{Reason} : ' ',)
                    );
		            $cv->send(1);
		            return;
                }
                return if ( $hdr->{OrigStatus} and $hdr->{OrigStatus} == 200 ) or $hdr->{Status} == 200;
                if ( $status == 500 or $status == 503 or $status =~ /^59/ ) {
                    my $w; $w = AE::timer( $self->retry_interval, 0, sub {
                        $first_task->{pos}  = $first_task->{ofs}; # 重下本块时要 seek 回零
                        $first_task->{size} = 0;
                        $first_task->{ctx}  = undef;
                        $run->(++$retry); 
                        undef $w;
                    });
                }
                else {
		            $self->error( 
                        sprintf("Status: %s, Reason: %s.", 
			        	    $status ? $status : '500', 
                            $hdr->{Reason} ? $hdr->{Reason} : ' ',)
                    );
		            $cv->send(1);
                    return
                }

            }
    };
    $cv->begin;
    $run->(0);
}

sub shuffle_url {
    my $self = shift;
    my $urls = $self->url_status;
    return (shuffle keys %$urls)[0];
}

sub on_body {
    my ($self, $task) = @_; 
    return sub {
        my ($partial_body, $hdr) = @_;
        return 0 unless ($hdr->{Status} == 206 || $hdr->{Status} == 200);

        my $len = length($partial_body);
        # 主要是用于解决第一个块会超过写的位置
        if ( $task->{size} + $len > $self->seg_size ) {
            my $spsize = $len - ( $task->{size} + $len - $self->seg_size );
            $partial_body = substr($partial_body, 0, $spsize);
            $len = $spsize; 
        }

        seek($self->fh, $task->{pos}, 0); 
        syswrite($self->fh, $partial_body) != $len and return 0;

        # 写完的记录
        if ( $self->digest ) {
            $task->{ctx} ||= AnyEvent::Digest->new($self->digest);
            $task->{ctx}->add_async($partial_body);
        }
        $task->{pos}   += $len;
        $task->{size}  += $len;
        return 1;
    }
}
sub fetch_chunk {
    my ($self, $cv, $task, $retry) = @_; 
    $retry ||= 0;
    my $url   = $self->shuffle_url;

    my $ev; $ev = http_get $url,
        timeout     => $self->timeout,
        recurse     => $self->recurse,
        persistent  => 1,
        keepalive   => 1,
        headers     => { 
            %{ $self->headers }, 
            Range => $task->{range} 
        },
        on_body => $self->on_body($task),
        sub {
            my ($hdl, $hdr) = @_;
            my $status = $hdr->{Status};
            undef $ev;
            if ( $retry > $self->max_retries ) {
	            $self->error( 
                    sprintf("Too many failures, Status: %s, Reason: %s.", 
		        	    $status ? $status : '500', 
                        $hdr->{Reason} ? $hdr->{Reason} : ' ',)
                ) if !$self->error;
                $self->url_status->{$url}++;
                $cv->send(1);
                return;
            }

            # 成功
            # 1. 需要对比大小是否一致, 接着对比块较检
            # 2. 开始下一个任务的下载
            # 3. 当前块就退出, 不然下面会重试
            if ( $status == 200 || $status == 206  ) {
                if ($task->{size} == ( $task->{tail} -$task->{ofs} + 1 ) ) {
                    # 三种情况
                    # 1. 大小不相等 | 进入下面的重试看是否有可能成功
                    # 2. 大小相等, 块较检不相等 | 直接失败
                    # 3. 大小相等, 块较检相等
                    $self->on_seg_finish->( 
                            $hdl, 
                            $task, 
                            $self->digest ? $task->{ctx}->hexdigest : '', 
                        sub {
                            my ($result, $error) = @_;
                            # 2. 大小相等, 块较检不相等 | 直接失败
                            if (!$result) {
                                $self->error("The $task->{chunk} block the compared failure");
                                $self->url_status->{$url}++;
                                $cv->send(1); # 失败, 结束整个请求
                                AE::log debug => $self->error;
                                return;
                            }
                            else {
                                # 情况 3, 大小相等, 块较检相等, 当前块下载完成, 开始下载新的 
                                AE::log debug => "地址 $url 的块 $task->{chunk} 下载完成 $$";
                                my $chunk_task = shift @{ $self->tasks };
                                # 处理接下来的一个请求
                                if ( $chunk_task ) {
                                    $self->fetch_chunk($cv, $chunk_task);
                                }
                                else {
                                    $cv->end;  # 完成, 标记结束本次请求
                                    return; 
                                }
                            }
                        }
                    );
                    return;
                }
            } 

	        $self->error( 
                sprintf("Chunk %s the size is wrong, expect the size: %s actual size: %s, The %s try again,  Status: %s, Reason: %s.", 
                    $task->{chunk},
                    $self->seg_size,
                    $task->{size},
                    $retry,
		    	    $status ? $status : '500', 
                    $hdr->{Reason} ? $hdr->{Reason} : ' ', )
            );
            AE::log warn => $self->error;
            $self->url_status->{$url}++;
            
            # 失败
            # 1. 如果有可能还连接上的响应, 就需要重试, 直到达到重试
            # 2. 如果不可能连接的响应, 就直接快速的退出
            if ( $status =~ /^(59.|503|500|502|200|206|)$/ ) {
                $self->retry($cv, $task, $retry);
            }
            else {
                # 直接失败
                $cv->send(1);
                return;
            }
        };
    $self->task_lists->[$task->{chunk}] = $ev;
}

sub retry {
    my ($self, $cv, $task, $retry) = @_;
    my $w;$w = AE::timer( $self->retry_interval, 0, sub {
        $task->{pos}  = $task->{ofs}; # 重下本块时要 seek 回零
        $task->{size} = 0;
        $task->{ctx}  = undef;
        $self->fetch_chunk( $cv, $task, ++$retry );
        undef $w;
    });
}

sub split_range {
    my $self    = shift;
    my $length  = shift;

    # 每个请求的段大小的范围,字节
    my $seg_size   = $self->seg_size;
    my $segments   = int($length / $seg_size);

    # 要处理的字节的总数
    my $len_remain = $length;

    my @ranges;
    my $chunk = 0;
    while ( $len_remain > 0 ) {
        # 每个 segment  的大小
        my $seg_len = $seg_size;

        # 偏移长度
        my $ofs = $length - $len_remain;
        
        # 剩余字节
        $len_remain -= $seg_len;

        my $tail  = $ofs + $seg_len - 1; 
        if ( $length-1  < $tail) {
            $tail = $length-1;
        }

        my $task  = { 
            chunk => $chunk, # 当前块编号
            ofs   => $ofs,   # 当前的偏移量
            pos   => $ofs,   # 本块的起点
            tail  => $tail,  # 本块的结束
            range => 'bytes=' . $ofs . '-' . $tail, 
            size  => 0,      # 总共下载的长度
        }; 

        $self->tasks->[$chunk] = $task; 
        $chunk++;
    }
}

sub move_to {
    my $self = shift;

    close $self->fh;
    my $dir  = File::Basename::dirname( $self->content_file );
    if (! -e $dir ) {
        if (! File::Path::make_path( $dir ) || ! -d $dir ) {
            my $e = $!;
        }
    }
    File::Copy::copy( $self->fh->filename, $self->content_file )
          or die "Failed to rename $self->fh->filename to $self->content_file: $!";

    unlink $self->fh->filename;
    delete $self->{fh};
}

sub clean {
    my $self = shift;
    close $self->fh;
    unlink $self->fh->filename;
    delete $self->{fh};
}

sub size {
  return 0 unless defined(my $file = shift->content_file);
  return -s $file;
}

1;

__END__

=pod
 
=encoding utf8

=head1 NAME

AnyEvent::MultiDownload - 非阻塞的多线程多地址文件下载的模块

=head1 SYNOPSIS

这是一个全非阻塞的多线程多地址文件下载的模块, 可以象下面这个应用一样, 同时下载多个文件, 并且整个过程都是异步事件解发, 不会阻塞主进程.

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
            my ($hdr, $chunk_obj, $md5, $cb) = @_;
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

=head1 METHODS

创建一个多下载的对象.

    my @urls = (
        'http://mirrors.163.com/ubuntu-releases/12.04/ubuntu-12.04.2-desktop-i386.iso',
        'http://releases.ubuntu.com/12.04.2/ubuntu-12.04.2-desktop-i386.iso',
    );
    my $MultiDown = AnyEvent::MultiDownload->new( 
            url     => shift @urls, 
            mirror  => \@urls, 
            content_file  => $content_file,
            seg_size => 1 * 1024 * 1024, # 1M
            on_seg_finish => sub {
                my ($hdr, $chunk_obj, $md5, $cb) = @_;
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

=over 8

=item url => 下载的主地址

这个是下载用的 master 的地址, 是主地址, 这个参数必须有.

=item content_file => 下载后的存放地址

这个地址用于指定, 下载完了, 存放在什么位置. 这个参数必须有.

=item mirror => 镜象地址

这个是可以用来做备用地址和分块下载时用的地址. 需要一个数组引用, 其中放入这个文件的其它用于下载的地址. 如果块下载失败会自动切换成其它的地址下载. 本参数不是必须的.

=item seg_size => 下载块的大小

默认这个 seg_size 是指每次取块的大小, 默认是 1M 一个块, 这个参数会给文件按照 1M 的大小来切成一个个块来下载并合并. 本参数不是必须的.

=item digest

用于指定所使用的块较检所使用的模块, 支持 Digest::MD5 和 Digest::SHA1

=item retry_interval => 重试的间隔 

重试的间隔, 默认为 10 s.

=item max_retries => 最多重试的次数

重试每个块所能重试的次数, 默认为 5 次.

=item max_per_host => 每个主机最多的连接数量

目前模块没有开发总连接数控制, 主要原因是.多线路为了快,所以控制单个主机的并发比控制总体好. 默认为 8. 并且一个 url 最多这么多请求.

=item headers => 自定义的 header

如果你想自己定义传送的 header , 就在这个参数中加就好了, 默认是一个哈希引用.

=item timeout

下载多久算超时, 可选参数, 默认为 60s.

=item recurse 重定向

如果请求过程中有重定向, 可以最多重定向多少次.

=back

=head2 multi_get_file()

事件开始的方法. 只有调用这个函数时, 这个下载的事件才开始执行.

=head1 callback

=head2 on_seg_finish

当每下载完 1M 时,会回调一次, 你可以用于检查你的下载每块的完整性, 这个时候只有 200 和 206 响应的时候才会回调.

回调传四个参数, 本块下载时响应的 header, 当前块的信息的引用 ( 包含 chunk 第几块, size 下载块的大小, pos 块的开始位置 ), 检查的 md5 的结果, 最后一个参数为处理完后的回调. 这时如果回调为 1 证明检查结果正常, 如果为 0 证明检查失败, 会在次重新下载本块. 

默认模块会帮助检查大小, 所以大小不用对比和检查了, 这个地方会根据 $self->digest 指定的信息, 给每块的 MD5 或者 SHA1 记录下来, 使用这个来对比. 本参数不是必须的. 如果没有这个回调默认检查大小正确.

=head2 on_finish

当整个文件下载完成时的回调, 下载完成的回调会传一个下载的文件大小的参数过来. 这个回调必须存在.

=head2 on_error

当整个文件下载过程出错时回调, 这个参数必须存在, 因为不能保证每次下载都能正常.


=head1 AUTHOR

扶凯 fukai <iakuf@163.com>

=cut
