require 'rubygems'
require 'sinatra'
require 'data_mapper'
require 'sqlite3'
require 'dm-sqlite-adapter'
require 'dm-postgres-adapter'
require 'json'
require 'rack-flash'

require 'haml'
require 'sass'
require "sinatra/authorization"

require 'openssl'
require 'net/http'
require 'uri'
require 'csv'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

#If on Heroku, uses Heroku database. 
DataMapper.setup(:default, ENV['DATABASE_URL'] || "sqlite3://#{Dir.pwd}/development.db")

class Book
  include DataMapper::Resource  
  property 		:id,           		Serial
	property		:isbn,				 		String,	:required => true, :unique => true
  property 		:title,        		Text
	property		:author1_first, 	String
	property		:author1_last,		String	
	property		:all_authors,			Text
	property		:subtitle, 		 		Text
	property		:publisher, 	 		String
	property		:pub_date,		 		Date
	property		:img_url, 		 		Text
	property		:small_img_url,		Text
	property		:preview_link,		Text
	property 		:page_count, 			Integer
	belongs_to 	:dewey_class, 		:required => false
	
	def dewey100
		return nil unless dewey_class_number
		dewey_class_number / 100 * 100
	end
	
	def dewey10
		return nil unless dewey_class_number
		dewey_class_number / 10 * 10
	end
end 

class DeweyClass
	include DataMapper::Resource 
	property		:number,				Integer, :key => true	
	property		:description,		String
	property		:granularity,		Integer
	has n,			:books	
	
	def full_description
		parent ? parent.full_description + " > " + description : description
	end
	
	def top_level_description
		parent ? parent.top_level_description : description
	end
	
	def parent
		if number % 10 == 0
			return number % 100 == 0 ? nil : DeweyClass.get(number / 100 * 100)
		else
			return DeweyClass.get(number / 10 * 10) || DeweyClass.get(number / 100 * 100)
		end
	end
end

DataMapper.auto_upgrade!

require './seeds.rb' unless DeweyClass.any?

enable :sessions
use Rack::Flash

helpers do
	def get_book_data(isbn)
		uri = URI.parse("https://www.googleapis.com/books/v1/volumes?q=isbn:#{isbn}&projection=lite")
		request = Net::HTTP::Get.new(uri.request_uri)
		socket = Net::HTTP.new(uri.host, uri.port)
		socket.use_ssl = true
		
		#Only on Heroku
		socket.verify_mode = OpenSSL::SSL::VERIFY_PEER 
		socket.ca_file = '/usr/lib/ssl/certs/ca-certificates.crt'
		#----
		
		store = OpenSSL::X509::Store.new
		store.add_cert OpenSSL::X509::Certificate.new(File.new('certs/googleapis.pem'))
		socket.cert_store = store
		google_response = socket.request(request)
		JSON.parse(google_response.body)
	end
	
	def clean_up_date(date)
		if date =~ /\d{4}-\d{2}-\d{2}/
			return date
		elsif date =~ /(\d{4})-(\d{2})/
			return "#{$1}-#{$2}-01"
		elsif date =~ /(\d{4})/
			return "#{$1}-01-01"
		end
	end
	
	include Sinatra::Authorization
	
	def authorization_realm
		"pilcrow"
	end
	
	def authorize(login, password)
	  login == "chris" && password == "books"
	end
end

#Index
['/', '/books'].each do |path|
	get path do
		@books = Book.all(:dewey_class_number.not => nil, :order => [:dewey_class_number.asc, :author1_last.asc, :author1_first.asc, :title.asc])
		haml :index
	end
end

#Index-unclassified
get '/books/unclassified' do
	@books = Book.all(:dewey_class_number => nil)
	haml :unclassified
end

#New
get '/books/new' do
	login_required
	haml :new
end

#Show
get '/books/:id' do
	@book = Book.get!(params[:id])
	haml :show
end

#Create
post '/books' do
	login_required
	if temp = Book.first(:isbn => params[:isbn])
		flash[:alert] = "<strong>#{temp.title}</strong> is already in the library."
		redirect '/books/new'
	else
		begin
			book_data = get_book_data(params[:isbn])
			this_book = book_data['items'][0]['volumeInfo']
			if this_book['authors']
				author1_first = this_book['authors'][0].split(" ")[0..-2].join(" ")
				author1_last = this_book['authors'][0].split(" ")[-1]
				all_authors = this_book['authors'].join(', ')
			else
				author1_first = author1_last = ""
			end
			if this_book['imageLinks']
				img_url = this_book['imageLinks']['thumbnail']
				small_img_url = this_book['imageLinks']['smallThumbnail']
			else
				img_url = small_img_url = ""
			end
			@book = Book.new({ :isbn 					=> 	params[:isbn],
												:title 					=> 	this_book['title'],
												:subtitle 			=> 	this_book['subtitle'],
												:author1_first	=>	author1_first,
												:author1_last		=> 	author1_last,
												:all_authors		=> 	all_authors,
												:publisher			=> 	this_book['publisher'],
												:pub_date				=> 	clean_up_date(this_book['publishedDate']),
												:img_url				=> 	img_url,
												:small_img_url 	=>	small_img_url,
												:preview_link 	=> 	this_book['previewLink'], 
												:page_count			=>	this_book['pageCount']
											})
		rescue => e
			flash[:alert] = "Sorry, something went wrong: #{e}<br><br>Bookdata: #{book_data}"
			redirect 'books/new'
		end
		if @book.save
			redirect "/books/#{@book.id}/edit"
		else
			flash[:alert]= "The following errors were reported: #{@book.errors.values.flatten.join(", ")}"
			redirect 'books/new'
		end
	end
end

#Edit
get '/books/:id/edit' do
	login_required
	@book = Book.get!(params[:id])
	@dewey100		= DeweyClass.all(:granularity => 100)
	@dewey10	 	= DeweyClass.all(:granularity => [100, 10])
	@dewey1 		= DeweyClass.all
	haml :edit
end

#Update
put '/books/:id' do
	login_required
	book = Book.get!(params[:id])
	book.dewey_class_number = params[:dewey1] || params[:dewey10] || params[:dewey100]
	book.save
	redirect Book.count(:dewey_class_number => nil) == 0 ? "/books/#{params[:id]}" : "/books/unclassified"
end

#upgrade!!!
get '/upgrade' do
	login_required
	Book.all.each do |book|
		book_data = get_book_data(book.isbn)
		this_book = book_data['items'][0]['volumeInfo']
		book.preview_link = this_book['previewLink']
		book.page_count	= this_book['pageCount']
		book.save
	end
	flash[:alert] = "Upgraded."
	redirect '/'
end

#Delete
get '/books/:id/delete' do
	login_required
	book = Book.get!(params[:id])
	book.destroy
	redirect Book.count(:dewey_class_number => nil) == 0 ? "/books" : "/books/unclassified"
end



