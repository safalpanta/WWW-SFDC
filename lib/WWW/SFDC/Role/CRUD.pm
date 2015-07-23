package WWW::SFDC::Role::CRUD;
# ABSTRACT: Shared methods between partner and tooling APIs

use 5.12.0;
use strict;
use warnings;

# VERSION

use Data::Dumper;
use List::NSect 'spart';
use Log::Log4perl ':easy';
use Scalar::Util 'blessed';
use SOAP::Lite;

use Moo::Role;
requires qw'_prepareSObjects';

=method query

If the query() API call is incomplete and returns a queryLocator, this
library will continue calling queryMore() until there are no more records to
recieve, at which point it will return the entire list:

  say $_->{Id} for WWW::SFDC->new(...)->Partner->query($queryString);

OR:

Execute a callback for each batch returned as part of a query. Useful for
reducing memory usage and increasing efficiency handling huge queries:

  WWW::SFDC->new(...)->Partner->query({
    query => $queryString,
    callback => \&myMethod
  });

This will return the result of the last call to &myMethod.

=method queryAll

This has the same additional behaviour as query().

=cut

sub _queryMore {
  my ($self, $locator) = @_;
  my ($result, $headers) = $self->_call(
    'queryMore',
    SOAP::Data->name(queryLocator => $locator),
  );
  return $result;
}

# Extract the results from a $request. This handles the case
# where there is only one result, as well as 0 or more than 1.
# They require different handling because in the 1 case, you
# can't handle it as an array
sub _getQueryResults {
  my ($self, $request) = @_;
  TRACE Dumper $request;
  return ref $request->{records} eq 'ARRAY'
    ? map {$self->_cleanUpSObject($_)} @{$request->{records}}
    : ( $self->_cleanUpSObject($request->{records}) );
}

# Unbless an SObject, and de-duplicate the ID field - SFDC
# duplicates the ID, which is interpreted as an arrayref!
sub _cleanUpSObject {
  my ($self, $obj) = @_;
  return () unless $obj;
  my %copy = %$obj; # strip the class from $obj
  $copy{Id} = $copy{Id}->[0] if $copy{Id} and ref $copy{Id} eq "ARRAY";
  delete $copy{Id} unless $copy{Id};

  while (my ($key, $entry) = each %copy) {
    next unless blessed $entry;
    if (blessed $entry eq 'sObject') {
      $copy{$key} = $self->_cleanUpSObject($entry);
    } elsif (blessed $entry eq 'QueryResult') {
      $entry = [
        ref $entry->{records} eq 'ARRAY'
          ? map {$self->_cleanUpSObject($_)} @{$entry->{records}}
          : $self->_cleanUpSObject($entry->{records})
      ];
    }
  }

  return \%copy;
}

# Chain together calls to _queryMore() and handle the results.
sub _completeQuery {
  my ($self, %params) = @_;

  LOGDIE "You must provide a query string!" unless $params{query};
  INFO "Executing SOQL query: $params{query}";

  my ($request, $headers) = $self->_call(
    $params{method},
    SOAP::Data->name(queryString => $params{query})
  );


  my $callback = $params{callback} || sub {
    TRACE Dumper \@_;
    state @results;
    push @results, @_;
    return @results;
  };

  my @result = $callback->($self->_getQueryResults($request));
  until ($request->{done} eq 'true') {
    $self->_sleep();
    $request = $self->_queryMore($request->{queryLocator});
    @result = $callback->($self->_getQueryResults($request));
  }

  return @result;
}

sub query {
  my ($self, $params) = @_;
  return $self->_completeQuery(
    ref $params
      ? %$params
      : (query => $params),
    method => 'query'
  );
}

sub queryAll {
  my ($self, $params) = @_;
  return $self->_completeQuery(
    ref $params
      ? %$params
      : (query => $params),
    method => 'queryAll'
  );

}

=method create

  say "$$_{id}:\t$$_{success}" for WWW::SFDC->new(...)->Partner->create(
    {type => 'thing', Id => 'foo', Field__c => 'bar', Name => 'baz'}
    {type => 'otherthing', Id => 'bam', Field__c => 'bas', Name => 'bat'}
  );

Create chunks your SObjects into 200s before calling create(). This means that if
you have more than 200 objects, you will incur multiple API calls.

=cut

sub create {
  my $self = shift;

  return map {
    $self->_call(
      'create',
      $self->_prepareSObjects(@$_)
    );
  } spart 200, @_;
}

=method update

  say "$$_{id}:\t$$_{success}" for WWW::SFDC::Partner->instance()->update(
    {type => 'thing', Id => 'foo', Field__c => 'bar', Name => 'baz'}
    {type => 'otherthing', Id => 'bam', Field__c => 'bas', Name => 'bat'}
  );

Returns an array that looks like [{success => 1, id => 'id'}, {}...] with LOWERCASE keys.

=cut

sub update {
  my $self = shift;

  TRACE "Objects for update" => \@_;
  INFO "Updating objects";

  return $self->_call(
    'update',
    $self->_prepareSObjects(@_)
   );
}

=method delete

  say "$$_{id}:\t$$_{success}" for WWW::SFDC::Partner->instance()->delete(@ids);

Returns an array that looks like [{success => 1, id => 'id'}, {}...] with LOWERCASE keys.

=cut

sub delete {
    my $self = shift;

    DEBUG "IDs for deletion" => \@_;
    INFO "Deleting objects";

    return $self->_call(
        'delete',
        map {SOAP::Data->name('ids' => $_)} @_
    );
}

=method undelete

  say "$$_{id}:\t$$_{success}" for WWW::SFDC::Partner->instance()->undelete(@ids);

Returns an array that looks like [{success => 1, id => 'id'}, {}...] with LOWERCASE keys.

=cut

sub undelete {
    my $self = shift;

    DEBUG "IDs for undelete" => \@_;
    INFO "Deleting objects";

    return $self->_call(
        'undelete',
        map {SOAP::Data->name('ids' => $_)} @_
    );
}

=method retrieve

Retrieves SObjects by ID. Not to be confused with the metadata retrieve method.

=cut

sub retrieve {
    my $self = shift;

    DEBUG "IDs for retrieve" => \@_;
    INFO "Retrieving objects";

    return $self->_call(
        'retrieve',
        map {SOAP::Data->name('ids' => $_)} @_
    );
}

1;

__END__

=head1 BUGS

Please report any bugs or feature requests at L<https://github.com/alexander-brett/WWW-SFDC/issues>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc WWW::SFDC::Role::CRUD

You can also look for information at L<https://github.com/alexander-brett/WWW-SFDC>
